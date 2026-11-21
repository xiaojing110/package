'use strict';
'require baseclass';
'require upnp.mappings as upnp';

return baseclass.extend({
	title: _('Active UPnP IGD & PCP/NAT-PMP Port Maps'),

	load: function() {
		return upnp.getStatus();
	},

	render: function(rules) {
		return upnp.renderTable(rules);
	}
});
