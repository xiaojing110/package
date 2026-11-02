'use strict';
'require daeuniverse.service as service';

return service.View.extend({
	app: {
		name: 'dae',
		title: 'dae',
		// Both create dae0/daens and hook the same interfaces: only one may run.
		other: 'honk',
		defaultConfig: '/etc/dae/config.dae',
		// Runs before a reload; on failure the service keeps its old configuration.
		validate: [ '/usr/bin/dae', [ 'validate', '-c' ] ],
		// procd forwards stdout as "dae[pid]:", the init script logs as "dae:".
		logIdent: /^dae(\[\d+\])?: /
	}
});
