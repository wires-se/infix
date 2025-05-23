
from collections import namedtuple
from dataclasses import dataclass

import logging
import socket
import sys
import time
import uuid   # For _ncc_get_data() extension
import os
import copy
import re

import libyang
import lxml
import netconf_client.connect
import netconf_client.ncclient
from infamy.transport import Transport,infer_put_dict
from netconf_client.error import RpcError
from . import env, netutil


def netconf_syn(addr):
    if netutil.tcp_port_is_open(addr, 830):
        print(f"{addr} answers to TCP connections on port 830 (NETCONF)")
        return True
    else:
        return False


modinfo_fields = ("identifier", "version", "format", "namespace")
ModInfoTuple = namedtuple("ModInfoTuple", modinfo_fields)


class ModInfo(ModInfoTuple):
    def xmlns(self):
        return f"xmlns:{self.identifier}=\"{self.namespace}\""


NS = {
    "ietf-netconf-monitoring": "urn:ietf:params:xml:ns:yang:ietf-netconf-monitoring",
    "nc": "urn:ietf:params:xml:ns:netconf:base:1.0",
}


class Manager(netconf_client.ncclient.Manager):
    """Wrapper for the real manager

    Just ensures that we can enable debugging without issues when
    operating on an IPv6 socket.

    """
    def _fetch_connection_ip(self):
        """Retrieves and stores the connection's local and remote IP"""
        self._local_ip = None
        self._peer_ip = None
        try:
            self._local_ip = self.session.sock.sock.getsockname()[0]
            self._peer_ip = self.session.sock.sock.getpeername()[0]
            print(f"Connection status\n\tLocal IP: {self._local_ip}\n"
                  "\tPeer IP: {self._peer_ip}")
        except (AttributeError, socket.error) as err:
            print(f"Failed connecting, status: {err}")
            pass

    def _debug(self):
        self.set_logger_level(logging.DEBUG)
        self.logger().addHandler(logging.StreamHandler(sys.stderr))


class NccGetDataReply:
    """Fold in to DataReply class when upstreaming"""
    def __init__(self, raw, ele):
        self.data_ele = ele.find("{urn:ietf:params:xml:ns:yang:ietf-netconf-nmda}data")
        self.data_xml = lxml.etree.tostring(self.data_ele)
        self.raw_reply = raw


class NccGetSchemaReply:
    def __init__(self, raw):
        self.ele = lxml.etree.fromstring(raw.xml.decode())
        self.ele = self.ele.find("{urn:ietf:params:xml:ns:yang:ietf-netconf-monitoring}data")
        self.schema = self.ele.text


@dataclass
class Location:
    interface: str
    host: str
    username: str
    password: str
    port: int = 830


class Device(Transport):
    def __init__(self,
                 name: str,
                 location: Location,
                 mapping: dict,
                 yangdir: None | str = None):
        print("Testing using NETCONF")

        self.name = name
        self.location = location
        self.mapping = mapping
        self.location = location
        self.ly = libyang.Context(yangdir)
        self._ncc_init(location)
        # self.ncc._fetch_connection_ip()
        # self.ncc._debug()

        self.modules = {}
        self._ly_bootstrap(yangdir)

        del self.ly
        self.ly = libyang.Context(yangdir)
        self._ly_init(yangdir)

    def __str__(self):
        nm = f"{self.name}"
        if env.ENV.ltop:
            nm += f"({env.ENV.ltop.xlate(self.name)})"
        return nm + " [NETCONF]"

    def _ncc_init(self, location):
        ai = socket.getaddrinfo(location.host, location.port,
                                0, 0, socket.SOL_TCP)
        sock = socket.socket(ai[0][0], ai[0][1], 0)
        sock.settimeout(60)
        print(f"Connecting to mgmt IP {location.host}:{location.port} ...")
        try:
            sock.connect(ai[0][4])
        except InterruptedError as err:
            print(f"Connection interrupted: {err}")
            raise err
        except TimeoutError as err:
            print(f"Connection timeout: {err}")
            raise err
        sock.settimeout(None)

        session = netconf_client.connect.connect_ssh(sock=sock,
                                                     username=location.username,
                                                     password=location.password)
        self.ncc = Manager(session)

    def _ly_bootstrap(self, yangdir):
        self.modules["ietf-netconf-monitoring"] = {
            "name": "ietf-netconf-monitoring"
        }

        for val in self.modules.values():
            mod = self.ly.load_module(val["name"])
            mod.feature_enable_all()
        schemas = self.get_schemas_list()
        for schema in schemas:
            if os.path.exists(yangdir + "/" + schema['filename']) is False:
                self.get_schema(schema, yangdir)

        print("YANG models downloaded.")

    def _ly_init(self, yangdir):
        self.ly = libyang.Context(yangdir)

        lib = self.ly.load_module("ietf-yang-library")
        ns = libyang.util.c2str(lib.cdata.ns)

        xml = lxml.etree.tostring(self.ncc.get(filter=f"""
        <filter type="subtree">
          <modules-state xmlns="{ns}" />
        </filter>""").data_ele[0])

        data = self.ly.parse_data("xml", libyang.IOType.MEMORY,
                                  xml, parse_only=True).print_dict()

        self.modules = {m["name"]: m for m in data["modules-state"]["module"]}

        for ms in self.modules.values():
            if ms["conformance-type"] != "implement":
                continue

            mod = self.ly.load_module(ms["name"])

            # TODO: ms["feature"] contains the list of enabled
            # features, so ideally we should only enable the supported
            # ones. However, features can depend on each other, so the
            # naïve looping approach doesn't work.
            mod.feature_enable_all()

    def _modules_in_xpath(self, xpath):
        modnames = []

        # Find all referenced models
        for seg in xpath.split("/"):
            if ":" in seg:
                modname, _ = seg.split(":")
                modnames.append(modname)

        return list(filter(lambda m: m["name"] in modnames,
                           self.modules.values()))

    def _build_xpath_filter(self, xpath, get_data_xpath=False):
        """Helper function to build the XPath filter with the necessary xmlns."""
        if xpath:
            xmlns = " ".join([f"xmlns:{m['name']}=\"{m['namespace']}\""
                                for m in self._modules_in_xpath(xpath)])
            if get_data_xpath is True:
                return f'<xpath-filter {xmlns}>{xpath}</xpath-filter>'
            else:
                return f"<filter type=\"xpath\" select=\"{xpath}\" {xmlns} />"
        return None

    def _parse_response(self, response, parse):
        """Helper function to handle XML response parsing."""
        if not response:
            return None

        if not parse:
            return response.raw_reply

        if len(response.data_ele) == 0:
            return None

        cfg = lxml.etree.tostring(response.data_ele[0])
        parsed_data = self.ly.parse_data_mem(cfg, "xml", parse_only=True)

        return parsed_data

    def _ncc_make_rpc(self, guts, msg_id=None):
        if not msg_id:
            msg_id = uuid.uuid4()

        return '<rpc message-id="{id}" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">{guts}</rpc>' \
            .format(guts=guts, id=msg_id).encode("utf-8")

    def copy(self, source, target):
        cmd = f'''<copy-config>
        <target>
            <{target}/>
        </target>
        <source>
           <{source}/>
        </source>
        </copy-config>'''
        self.ncc._send_rpc(self._ncc_make_rpc(cmd))

    def reboot(self):
        """<system-restart xmlns="urn:ietf:params:xml:ns:yang:ietf-system"/>"""
        return self.call_dict("ietf-system", {
            "system-restart": {}
        })

    def get(self, xpath, parse=True):
        xpath_filter = self._build_xpath_filter(xpath)
        response = self.ncc.get(filter=xpath_filter)
        return self._parse_response(response, parse)

    def get_dict(self, xpath):
        """Return Python dictionary of <get> RPC data"""

        data = self.get(xpath)
        if not data:
            return None

        return data.print_dict()

    def get_data(self, xpath=None, parse=True):
        xpath_filter = self._build_xpath_filter(xpath, get_data_xpath=True)
        response = self.ncc.get_data(datastore="ds:operational", filter=xpath_filter)
        parsed_data = self._parse_response(response, parse)

        if parse and parsed_data:
            return parsed_data.print_dict()

        return parsed_data

    def get_config(self, xpath):
        xpath_filter = self._build_xpath_filter(xpath)
        response = self.ncc.get_config(source="running", filter=xpath_filter)
        return self._parse_response(response, True)

    def get_config_dict(self, xpath):
        """Get Python dictionary version of XML configuration"""
        return self.get_config(xpath).print_dict()

    def put_config(self, edit):
        """Send XML configuration over NETCONF"""
        yang2nc = {
            "none": None,
            "delete": "delete",
        }

        xml = f"<config xmlns=\"{NS['nc']}\" xmlns:nc=\"{NS['nc']}\">" \
            + edit + "</config>"

        # Translate any edit operations from the yang format generated
        # by diffing trees with libyang, to their NETCONF equivalents.
        for src, dst in yang2nc.items():
            xml = xml.replace(f"yang:operation=\"{src}\"",
                              f"nc:operation=\"{dst}\"" if dst else "")

        for _ in range(0, 3):
            try:
                self.ncc.edit_config(xml, default_operation='merge')
            except RpcError as _e:
                print(f"Failed sending edit-config RPC: {_e}  Retrying ...")
                time.sleep(1)
                continue
            break

    def put_config_dicts(self, models):
        """PUT full configuration of all models to running-config"""
        config = ""
        infer_put_dict(self.name, models)

        for model in models.keys():
            mod = self.ly.get_module(model)
            lyd = mod.parse_data_dict(models[model], no_state=True, validate=False)
            config += lyd.print_mem("xml", with_siblings=True, pretty=False) + "\n"
        # print(f"Send new XML config: {config}")
        return self.put_config(config)

    def put_config_dict(self, modname, edit):
        """Convert Python dictionary to XMl and send as configuration"""
        mod = self.ly.get_module(modname)
        lyd = mod.parse_data_dict(edit, no_state=True, validate=False)
        config = lyd.print_mem("xml", with_siblings=True, pretty=False)
        # print(f"Send new XML config: {config}")
        return self.put_config(config)

    def call(self, call):
        """Call RPC, XML version"""
        return self.ncc.dispatch(call)

    def call_dict(self, modname, call):
        """Call RPC, Python dictionary version"""
        mod = self.ly.get_module(modname)
        lyd = mod.parse_data_dict(call, rpc=True)
        return self.call(lyd.print_mem("xml", with_siblings=True, pretty=False))

    def call_action(self, xpath):
        """Call NETCONF action (contextualized RPC), XML version"""
        action={}
        pattern = r"^/(?P<module>[^:]+):(?P<path>[^/]+)"
        match = re.search(pattern, xpath)
        module = match.group('module')
        modpath = f"/{match.group('module')}:{match.group('path')}"
        libyang.xpath_set(action, xpath, {})
        mod = self.ly.get_module(module)
        lyd = mod.parse_data_dict(action, rpc=True)
        xml = "<action xmlns=\"urn:ietf:params:xml:ns:yang:1\">" + lyd.print_mem("xml", with_siblings=True, pretty=False) + "</action>"
        return self.ncc.dispatch(xml)

    def get_schemas_list(self):
        schemas = []
        data = self.get_dict("/netconf-state")

        for d in data["netconf-state"]["schemas"]["schema"]:
            schema = {}
            schema["identifier"] = d['identifier']
            schema["format"] = d["format"]
            if d['version']:
                schema["version"] = d['version']
                schema["filename"] = f"{d['identifier']}@{d['version']}.yang"
            else:
                schema["filename"] = f"{d['identifier']}.yang"
            schemas.append(schema)
        return schemas

    def get_schema(self, schema, outdir):
        query = {
            "get-schema": {
                "identifier": schema['identifier'],
                "version": schema['version'],
                "format": "yang"
            }
        }
        rpc_reply = self.call_dict("ietf-netconf-monitoring",  query)
        data = NccGetSchemaReply(rpc_reply)

        with open(outdir+"/"+schema["filename"], "w") as f:
            f.write(data.schema)

    def delete_xpath(self, xpath):
        # Split out the model and the container from xpath'
        pattern = r"^/(?P<module>[^:]+):(?P<path>[^/]+)"
        match = re.search(pattern, xpath)
        if not match:
            raise ValueError(f"Failed parsing xpath:{xpath}")

        module = match.group('module')
        path = match.group('path')
        modpath = f"/{module}:{path}"

        # Fetch current config
        old = self.get_config_dict(modpath)
        new = copy.deepcopy(old)

        # Perform deletion
        if not libyang.xpath_del(new, xpath):
            raise ValueError(f"Failed to delete specified xpath: {xpath}")

        # Parse old and new data to generate the diff
        mod = self.ly.get_module(module)
        oldd = mod.parse_data_dict(old, no_state=True, validate=False)
        newd = mod.parse_data_dict(new, no_state=True, validate=False)

        lyd = oldd.diff(newd)
        if lyd is None:
            raise ValueError(f"Failed generating diff for xpath:{xpath}")

        # Apply the configuration change
        return self.put_config(lyd.print_mem("xml", with_siblings=True,
                                             pretty=False))
