/* SPDX-License-Identifier: BSD-3-Clause */

#include <fnmatch.h>
#include <stdbool.h>

#include <jansson.h>

#include <arpa/inet.h>
#include <net/if.h>

#include "core.h"
#include "dagger.h"
#include "lyx.h"
#include "srx_module.h"
#include "srx_val.h"

static const char *iffeat[] = {
	"if-mib",
	NULL
};

static const struct srx_module_requirement ietf_if_reqs[] = {
	{ .dir = YANG_PATH_, .name = "ietf-interfaces", .rev = "2018-02-20", .features = iffeat },
	{ .dir = YANG_PATH_, .name = "iana-if-type", .rev = "2023-01-26" },
	{ .dir = YANG_PATH_, .name = "ietf-ip", .rev = "2018-02-22" },
	{ .dir = YANG_PATH_, .name = "infix-ip", .rev = "2023-04-24" },

	{ NULL }
};

static bool iface_is_phys(const char *ifname)
{
	bool is_phys = false;
	json_error_t jerr;
	const char *attr;
	json_t *link;
	FILE *proc;

	proc = popenf("re", "ip -d -j link show dev %s 2>/dev/null", ifname);
	if (!proc)
		goto out;

	link = json_loadf(proc, 0, &jerr);
	pclose(proc);

	if (!link)
		goto out;

	if (json_unpack(link, "[{s:s}]", "link_type", &attr))
		goto out_free;

	if (strcmp(attr, "ether"))
		goto out_free;

	if (!json_unpack(link, "[{s: { s:s }}]", "linkinfo", "info_kind", &attr))
		goto out_free;

	is_phys = true;

out_free:
	json_decref(link);
out:
	return is_phys;
}

static int ifchange_cand_infer_type(sr_session_ctx_t *session, const char *xpath)
{
	sr_val_t inferred = { .type = SR_STRING_T };
	sr_error_t err = SR_ERR_OK;
	char *ifname, *type;

	type = srx_get_str(session, "%s/type", xpath);
	if (type) {
		free(type);
		return SR_ERR_OK;
	}

	ifname = srx_get_str(session, "%s/name", xpath);
	if (!ifname)
		return SR_ERR_INTERNAL;

	if (iface_is_phys(ifname))
		inferred.data.string_val = "iana-if-type:ethernetCsmacd";
	else if (!fnmatch("br+([0-9])", ifname, FNM_EXTMATCH))
		inferred.data.string_val = "iana-if-type:bridge";
	else if (!fnmatch("lag+([0-9])", ifname, FNM_EXTMATCH))
		inferred.data.string_val = "iana-if-type:ieee8023adLag";
	else if (!fnmatch("vlan+([0-9])", ifname, FNM_EXTMATCH))
		inferred.data.string_val = "iana-if-type:l2vlan";
	else if (!fnmatch("*.+([0-9])", ifname, FNM_EXTMATCH))
		inferred.data.string_val = "iana-if-type:l2vlan";

	free(ifname);

	if (inferred.data.string_val)
		err = srx_set_item(session, &inferred, 0, "%s/type", xpath);

	return err;
}

static int ifchange_cand(sr_session_ctx_t *session, uint32_t sub_id, const char *module,
			 const char *xpath, sr_event_t event, unsigned request_id, void *priv)
{
	sr_change_iter_t *iter;
	sr_change_oper_t op;
	sr_val_t *old, *new;
	sr_error_t err;

	if (event != SR_EV_UPDATE)
		return SR_ERR_OK;

	err = sr_dup_changes_iter(session, "/ietf-interfaces:interfaces/interface", &iter);
	if (err)
		return err;

	while (sr_get_change_next(session, iter, &op, &old, &new) == SR_ERR_OK) {
		if (op != SR_OP_CREATED)
			continue;

		err = ifchange_cand_infer_type(session, new->xpath);
		if (err)
			break;
	}

	sr_free_change_iter(iter);
	return SR_ERR_OK;
}

static bool is_std_lo_addr(const char *ifname, const char *ip, const char *pf)
{
	struct in6_addr in6, lo6;
	struct in_addr in4;

	if (strcmp(ifname, "lo"))
		return false;

	if (inet_pton(AF_INET, ip, &in4) == 1)
		return (ntohl(in4.s_addr) == INADDR_LOOPBACK) && !strcmp(pf, "8");

	if (inet_pton(AF_INET6, ip, &in6) == 1) {
		inet_pton(AF_INET6, "::1", &lo6);

		return !memcmp(&in6, &lo6, sizeof(in6))
			&& !strcmp(pf, "128");
	}

	return false;
}

static sr_error_t netdag_gen_ipvx_addr(FILE *ip, const char *ifname,
				       struct lyd_node *addr)
{
	enum lydx_op op = lydx_get_op(addr);
	const char *oip, *opf, *nip, *npf;
	const char *addcmd = "add";

	nip = lydx_get_cattr(addr, "ip");
	npf = lydx_get_cattr(addr, "prefix-length");
	if (!nip || !npf)
		return SR_ERR_INVAL_ARG;

	if (op != LYDX_OP_CREATE) {
		oip = lydx_get_mattr(lydx_get_child(addr, "ip"), "yang:orig-value") ? : nip;
		opf = lydx_get_mattr(lydx_get_child(addr, "prefix-length"), "yang:orig-value") ? : npf;
		if (!oip || !opf)
			return SR_ERR_INVAL_ARG;

		fprintf(ip, "address delete %s/%s dev %s\n", oip, opf, ifname);

		if (op == LYDX_OP_DELETE)
			return SR_ERR_OK;
	}

	/* When bringing up loopback, the kernel will automatically
	 * add the standard addresses, so don't treat the existance of
	 * these as an error.
	 */
	if ((op == LYDX_OP_CREATE) && is_std_lo_addr(ifname, nip, npf))
		addcmd = "replace";

	fprintf(ip, "address %s %s/%s dev %s\n", addcmd, nip, npf, ifname);
	return SR_ERR_OK;
}

static sr_error_t netdag_gen_ipvx_addrs(FILE *ip, const char *ifname,
					struct lyd_node *addrs)
{
	sr_error_t err = SR_ERR_OK;
	struct lyd_node *addr;

	LYX_LIST_FOR_EACH(addrs, addr, "address") {
		err = netdag_gen_ipvx_addr(ip, ifname, addr);
		if (err)
			break;
	}

	return err;
}

static sr_error_t netdag_gen_ipv4(FILE *ip, const char *ifname,
				  struct lyd_node *ipv4)
{
	return netdag_gen_ipvx_addrs(ip, ifname, lyd_child(ipv4));
}

static sr_error_t netdag_gen_ipv6(FILE *ip, const char *ifname,
				  struct lyd_node *ipv6)
{
	return netdag_gen_ipvx_addrs(ip, ifname, lyd_child(ipv6));
}

static sr_error_t netdag_gen_iface(struct dagger *net, struct lyd_node *iface)
{
	const char *ifname = lydx_get_cattr(iface, "name");
	enum lydx_op op = lydx_get_op(iface);
	sr_error_t err = SR_ERR_INTERNAL;
	struct lyd_node *node;
	const char *attr;
	bool fixed;
	FILE *ip;

	fixed = iface_is_phys(ifname) || !strcmp(ifname, "lo");

	DEBUG("%s(%s) %s", ifname, fixed ? "fixed" : "dynamic",
	      (op == LYDX_OP_NONE) ? "mod" : ((op == LYDX_OP_CREATE) ? "add" : "del"));

	if (op == LYDX_OP_DELETE) {
		ip = dagger_fopen_current(net, "exit", ifname, 50, "delete.ip");
		if (!ip)
			goto err;

		if (fixed) {
			fprintf(ip, "link set dev %s down\n", ifname);
			fprintf(ip, "addr flush dev %s\n", ifname);
		} else {
			fprintf(ip, "link del dev %s\n", ifname);
		}

		fclose(ip);
		return SR_ERR_OK;
	}

	ip = dagger_fopen_next(net, "init", ifname, 50, "init.ip");
	if (!ip)
		goto err;

	attr = ((op == LYDX_OP_CREATE) && !fixed) ? "add" : "set";
	fprintf(ip, "link %s dev %s", attr, ifname);

	/* Generic attributes */

	attr = lydx_get_cattr(iface, "enabled");
	if (!attr && (op == LYDX_OP_CREATE))
		/* When adding an interface to the configuration, we
		 * need to bring it up, even when "enabled" is not
		 * explicitly set.
		 */
		attr = "true";

	attr = attr ? (!strcmp(attr, "true") ? " up" : " down") : "";
	fprintf(ip, "%s", attr);

	/* Type specific attributes */

	fputc('\n', ip);

	/* IP Addresses */

	node = lydx_get_child(iface, "ipv4");
	if (node) {
		err = netdag_gen_ipv4(ip, ifname, node);
		if (err)
			goto err_close_ip;
	}

	node = lydx_get_child(iface, "ipv6");
	if (node) {
		err = netdag_gen_ipv6(ip, ifname, node);
		if (err)
			goto err_close_ip;
	}

err_close_ip:
	fclose(ip);
err:
	return err;
}

static sr_error_t netdag_init(struct dagger *net, struct lyd_node *cifs,
			      struct lyd_node *difs)
{
	struct lyd_node *iface;

	LYX_LIST_FOR_EACH(cifs, iface, "interface")
		if (dagger_add_node(net, lydx_get_cattr(iface, "name")))
			return SR_ERR_INTERNAL;

	LYX_LIST_FOR_EACH(cifs, iface, "interface")
		if (dagger_add_node(net, lydx_get_cattr(iface, "name")))
			return SR_ERR_INTERNAL;

	return SR_ERR_OK;
}

static int ifchange(sr_session_ctx_t *session, uint32_t sub_id, const char *module,
		    const char *xpath, sr_event_t event, unsigned request_id, void *_confd)
{
	struct lyd_node *diff, *cifs, *difs, *iface;
	struct confd *confd = _confd;
	sr_data_t *cfg;
	sr_error_t err;

	switch (event) {
	case SR_EV_CHANGE:
		break;
	case SR_EV_ABORT:
		return dagger_abandon(&confd->netdag);
	case SR_EV_DONE:
		return dagger_evolve_or_abandon(&confd->netdag);
	default:
		return SR_ERR_OK;
	}

	err = dagger_claim(&confd->netdag, "/run/net");
	if (err)
		return err;

	err = sr_get_data(session, "/interfaces/interface//.", 0, 0, 0, &cfg);
	if (err)
		goto err_abandon;

	err = srx_get_diff(session, (struct lyd_node **)&diff);
	if (err)
		goto err_release_data;

	cifs = lydx_get_descendant(cfg->tree, "interfaces", "interface", NULL);
	difs = lydx_get_descendant(diff, "interfaces", "interface", NULL);

	err = netdag_init(&confd->netdag, cifs, difs);
	if (err)
		goto err_free_diff;

	LYX_LIST_FOR_EACH(difs, iface, "interface") {
		err = netdag_gen_iface(&confd->netdag, iface);
		if (err)
			break;
	}

err_free_diff:
	lyd_free_tree(diff);
err_release_data:
	sr_release_data(cfg);
err_abandon:
	if (err)
		dagger_abandon(&confd->netdag);

	return err;
}

int ietf_interfaces_init(struct confd *confd)
{
	int rc;

	rc = srx_require_modules(confd->conn, ietf_if_reqs);
	if (rc)
		goto fail;

	REGISTER_CHANGE(confd->session, "ietf-interfaces", "/ietf-interfaces:interfaces", 0, ifchange, confd, &confd->sub);

	sr_session_switch_ds(confd->session, SR_DS_CANDIDATE);
	REGISTER_CHANGE(confd->session, "ietf-interfaces", "/ietf-interfaces:interfaces",
			SR_SUBSCR_UPDATE, ifchange_cand, confd, &confd->sub);

	sr_session_switch_ds(confd->session, SR_DS_RUNNING);
	return SR_ERR_OK;
fail:
	ERROR("init failed: %s", sr_strerror(rc));
	return rc;
}
