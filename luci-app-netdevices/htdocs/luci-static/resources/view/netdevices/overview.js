'use strict';
'require view';
'require rpc';
'require ui';

var callStatus      = rpc.declare({ object: 'netdevices', method: 'status',         expect: { 'result': [] } });
var callSetStatic   = rpc.declare({ object: 'netdevices', method: 'set_static',     params: ['mac', 'ip', 'name'],        expect: { 'result': true } });
var callRemoveStatic= rpc.declare({ object: 'netdevices', method: 'remove_static',  params: ['mac'],                      expect: { 'result': true } });
var callKick        = rpc.declare({ object: 'netdevices', method: 'kick',           params: ['mac', 'ip'],                expect: { 'result': true } });
var callUnkick      = rpc.declare({ object: 'netdevices', method: 'unkick',         params: ['mac'],                      expect: { 'result': true } });
var callSetLimit    = rpc.declare({ object: 'netdevices', method: 'set_limit',      params: ['mac', 'down', 'up'],        expect: { 'result': true } });
var callRemoveLimit = rpc.declare({ object: 'netdevices', method: 'remove_limit',   params: ['mac'],                      expect: { 'result': true } });
var callSetFlags    = rpc.declare({ object: 'netdevices', method: 'set_flags',      params: ['traffic', 'app_usage'],     expect: { 'result': true } });
var callAppUsage    = rpc.declare({ object: 'netdevices', method: 'app_usage',      params: ['mac', 'ip'],                expect: { 'result': [] } });
var callCaps        = rpc.declare({ object: 'netdevices', method: 'caps',           expect: { 'result': {} } });
var callHelp        = rpc.declare({ object: 'netdevices', method: 'help',           expect: { 'result': {} } });

var autoTimer = null;

/* ---------------- 样式 ---------------- */
var CSS = [
	'.nd-wrap{font-size:13px}',
	'.nd-hero{background:linear-gradient(135deg,#2b6cb0 0%,#4299e1 60%,#63b3ed 100%);color:#fff;',
	'border-radius:10px;padding:16px 20px;margin-bottom:14px;box-shadow:0 3px 10px rgba(0,0,0,.12)}',
	'.nd-hero h2{margin:0 0 4px;color:#fff;font-size:19px}',
	'.nd-hero .sub{opacity:.85;font-size:12px}',
	'.nd-cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0}',
	'.nd-card{flex:1 1 120px;background:#fff;border:1px solid #e2e8f0;border-radius:8px;',
	'padding:10px 12px;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.05)}',
	'.nd-card .num{font-size:22px;font-weight:700;line-height:1.2}',
	'.nd-card .lbl{font-size:11px;color:#718096;margin-top:2px}',
	'.nd-tag{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600}',
	'.nd-on{background:#c6f6d5;color:#22543d}.nd-off{background:#fed7d7;color:#822727}',
	'.nd-ban{background:#feebc8;color:#7b341e}.nd-lim{background:#bee3f8;color:#2a4365}',
	'.nd-test{background:#e9d8fd;color:#44337a;border:1px dashed #805ad5}',
	'.nd-btn{display:inline-block;border:0;border-radius:5px;padding:4px 11px;margin:1px 3px 1px 0;',
	'font-size:12px;cursor:pointer;color:#fff;transition:opacity .15s}',
	'.nd-btn:hover{opacity:.82}',
	'.nd-b-blue{background:#3182ce}.nd-b-green{background:#38a169}.nd-b-red{background:#e53e3e}',
	'.nd-b-orange{background:#dd6b20}.nd-b-gray{background:#718096}.nd-b-purple{background:#805ad5}',
	'.nd-section{background:#fff;border:1px solid #e2e8f0;border-radius:8px;margin:12px 0;overflow:hidden}',
	'.nd-section>h3{margin:0;padding:10px 14px;background:#f7fafc;border-bottom:1px solid #e2e8f0;',
	'font-size:14px;color:#2d3748}',
	'.nd-section .body{padding:12px 14px}',
	'.nd-help ol{margin:6px 0 14px 20px}.nd-help li{margin:4px 0;line-height:1.7}',
	'.nd-help code{background:#edf2f7;padding:1px 6px;border-radius:4px;font-size:11px}',
	'.nd-switch{display:flex;align-items:center;gap:8px;padding:8px 0}',
	'.nd-switch input{width:16px;height:16px}',
	'.nd-table{width:100%;border-collapse:collapse}',
	'.nd-table th{background:#f7fafc;color:#4a5568;font-weight:600;font-size:12px;',
	'padding:8px 10px;text-align:left;border-bottom:2px solid #e2e8f0;white-space:nowrap}',
	'.nd-table td{padding:9px 10px;border-bottom:1px solid #edf2f7;vertical-align:middle}',
	'.nd-table tr:hover{background:#f7fafc}',
	'.nd-mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px}',
	'.nd-name{font-weight:600;color:#2d3748}',
	'.nd-unknown{color:#a0aec0;font-style:italic}',
	'.nd-bar{height:6px;background:#edf2f7;border-radius:3px;overflow:hidden;margin-top:3px}',
	'.nd-bar>i{display:block;height:100%;background:#4299e1}',
	'.nd-muted{color:#a0aec0;font-size:11px}'
].join('');

function injectCss() {
	if (document.getElementById('nd-css')) return;
	var s = document.createElement('style');
	s.id = 'nd-css';
	s.textContent = CSS;
	document.head.appendChild(s);
}

/* ---------------- 工具 ---------------- */
function fmtDur(s) {
	s = Math.max(0, parseInt(s) || 0);
	if (s < 60) return _('%d 秒').format(s);
	var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
	if (d > 0) return _('%d 天 %d 小时').format(d, h);
	if (h > 0) return _('%d 小时 %d 分').format(h, m);
	return _('%d 分钟').format(m);
}

function fmtTime(ts) {
	ts = parseInt(ts) || 0;
	if (ts <= 0) return '-';
	var d = new Date(ts * 1000);
	function p(n) { return (n < 10 ? '0' : '') + n; }
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
	       ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function fmtBytes(b) {
	b = parseInt(b) || 0;
	if (b <= 0) return '0 B';
	var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
	while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
	return b.toFixed(i === 0 ? 0 : 1) + ' ' + u[i];
}

function fmtRate(k) {
	k = parseInt(k) || 0;
	if (k <= 0) return _('不限速');
	if (k >= 1000) return (k / 1000).toFixed(k % 1000 ? 1 : 0) + ' Mbps';
	return k + ' Kbps';
}

function tag(txt, cls) {
	return E('span', { 'class': 'nd-tag ' + cls }, [txt]);
}

/* ---------------- 弹窗 ---------------- */
function modal(title, body, okLabel, onOk) {
	ui.showModal(title, body, [
		{
			'label': okLabel, 'class': 'btn cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(this, function () {
				return Promise.resolve(onOk()).then(function () { ui.hideModal(); });
			})
		},
		{ 'label': _('取消'), 'class': 'btn cbi-button', 'click': ui.hideModal }
	]);
}

function inputRow(label, el, hint) {
	return E('div', { 'style': 'margin-bottom:12px' }, [
		E('label', { 'style': 'display:block;font-weight:600;margin-bottom:4px' }, [label]),
		el,
		hint ? E('div', { 'class': 'nd-muted', 'style': 'margin-top:3px' }, [hint]) : null
	]);
}

function textInput(val, ph) {
	return E('input', {
		'type': 'text', 'class': 'cbi-input-text',
		'value': val || '', 'placeholder': ph || '', 'style': 'width:100%;padding:5px 8px'
	});
}

function notify(msg, ok) {
	ui.addNotification(null, E('p', {}, [msg]), ok ? 'info' : 'warning');
}

/* ---------------- 设备操作 ---------------- */
function doStatic(d, reload) {
	var ipEl = textInput((d.ip4 || '').split(',')[0], '192.168.1.100');
	var nmEl = textInput(d.name, _('设备名（可选）'));
	modal(_('设置静态地址'), E('div', {}, [
		inputRow(_('MAC 地址'), E('div', { 'class': 'nd-mono' }, [d.mac])),
		inputRow(_('IPv4 静态地址'), ipEl, _('保存后 dnsmasq 重新读取，设备续租时拿到固定地址')),
		inputRow(_('设备名'), nmEl)
	]), d.is_static ? _('更新') : _('保存'), function () {
		var ip = ipEl.value.trim();
		if (!ip) { notify(_('请输入 IPv4 地址')); return; }
		return callSetStatic(d.mac, ip, nmEl.value.trim()).then(function () {
			notify(_('静态地址已保存'), true); reload();
		});
	});
}

function doKick(d, reload) {
	modal(_('踢下线确认'), E('div', {}, [
		E('p', {}, [_('将对以下设备执行「踢下线」：')]),
		E('div', {
			'class': 'nd-mono', 'style': 'background:#fed7d7;padding:8px;border-radius:5px;margin:8px 0'
		}, [(d.name ? d.name + '  ·  ' : '') + d.mac + (d.ip4 ? '  ·  ' + d.ip4 : '')]),
		E('p', { 'class': 'nd-muted' }, [
			_('会执行：① 防火墙 MAC 封锁　② 清掉 DHCP 租约　③ WiFi 去关联。设备将无法上网。')
		])
	]), _('确认踢下线'), function () {
		return callKick(d.mac, (d.ip4 || '').split(',')[0]).then(function (r) {
			var bits = [];
			if (r && r.ban === false) bits.push(_('防火墙规则失败（缺 nft/fw4）'));
			if (r && r.wifi === false) bits.push(_('WiFi 去关联失败'));
			notify(bits.length ? _('已处理，但：') + bits.join('；') : _('设备已踢下线'), bits.length ? false : true);
			reload();
		});
	});
}

function doLimit(d, reload) {
	var downEl = textInput(d.limit_down > 0 ? d.limit_down : '', _('如 2000'));
	var upEl = textInput(d.limit_up > 0 ? d.limit_up : '', _('如 500'));
	modal(_('设置限速'), E('div', {}, [
		inputRow(_('MAC 地址'), E('div', { 'class': 'nd-mono' }, [d.mac])),
		inputRow(_('下行速率（Kbit/s）'), downEl, _('设备下载方向。0 或留空 = 不限速')),
		inputRow(_('上行速率（Kbit/s）'), upEl, _('设备上传方向。0 或留空 = 不限速')),
		E('div', { 'class': 'nd-muted' }, [
			_('例：下行 2000、上行 500 = 下载 2Mbps / 上传 500Kbps'),
			E('br'), _('限速基于内核 tc HTB/ifb；系统无 tc 时仅保存配置，不依赖额外软件包')
		])
	]), _('保存'), function () {
		return callSetLimit(d.mac, downEl.value.trim() || '0', upEl.value.trim() || '0').then(function () {
			notify(_('限速已生效'), true); reload();
		}).catch(function (e) {
			notify(_('限速失败：') + (e && e.message ? e.message : e));
		});
	});
}

function doAppUsage(d) {
	callAppUsage(d.mac, (d.ip4 || '').split(',')[0]).then(function (r) {
		var list = (r && r.result) ? r.result : (Array.isArray(r) ? r : []);
		var rows = list.map(function (x) {
			return E('tr', {}, [
				E('td', { 'style': 'padding:5px 8px' }, [x.service]),
				E('td', { 'class': 'nd-mono', 'style': 'padding:5px 8px;text-align:right' }, [String(x.connections)]),
				E('td', { 'class': 'nd-mono', 'style': 'padding:5px 8px;text-align:right' }, [fmtBytes(x.bytes)])
			]);
		});
		ui.showModal(_('App 使用记录（测试）') + ' - ' + (d.name || d.mac), E('div', {}, [
			E('div', { 'class': 'nd-tag nd-test', 'style': 'margin-bottom:10px' }, [
				_('⚠️ 测试功能 · 按目标端口启发式归类，无法识别具体 App 名称')
			]),
			rows.length ? E('table', { 'class': 'nd-table' }, [
				E('tr', {}, [
					E('th', {}, [_('服务类型')]),
					E('th', { 'style': 'text-align:right' }, [_('连接数')]),
					E('th', { 'style': 'text-align:right' }, [_('流量')])
				])
			].concat(rows)) : E('p', { 'class': 'nd-muted' }, [_('暂无数据（需先在「实验功能」里打开 App 使用记录）')])
		]), [{ 'label': _('关闭'), 'class': 'btn cbi-button', 'click': ui.hideModal }]);
	});
}

/* ---------------- 表格 ---------------- */
function renderTable(data, flags, reload) {
	var list = Array.isArray(data) ? data : [];
	list.sort(function (a, b) {
		if (a.banned !== b.banned) return a.banned ? 1 : -1;
		if (a.online !== b.online) return a.online ? -1 : 1;
		return (a.name || '').localeCompare(b.name || '');
	});

	var rows = list.map(function (d) {
		var ops = [];
		ops.push(E('button', { 'class': 'nd-btn nd-b-blue',  'click': ui.createHandlerFn(this, function () { doStatic(d, reload); }) },
			[d.is_static ? _('改静态') : _('静态地址')]));
		if (d.banned) {
			ops.push(E('button', { 'class': 'nd-btn nd-b-green', 'click': ui.createHandlerFn(this, function () {
				return callUnkick(d.mac).then(function () { notify(_('已解除封锁'), true); reload(); });
			}) }, [_('解除封锁')]));
		} else {
			ops.push(E('button', { 'class': 'nd-btn nd-b-red', 'click': ui.createHandlerFn(this, function () { doKick(d, reload); }) },
				[_('踢下线')]));
		}
		ops.push(E('button', { 'class': 'nd-btn nd-b-orange', 'click': ui.createHandlerFn(this, function () { doLimit(d, reload); }) },
			[d.limit_down > 0 ? _('改限速') : _('限速')]));
		if (d.limit_down > 0 || d.limit_up > 0) {
			ops.push(E('button', { 'class': 'nd-btn nd-b-gray', 'click': ui.createHandlerFn(this, function () {
				return callRemoveLimit(d.mac).then(function () { notify(_('已移除限速'), true); reload(); });
			}) }, [_('不限速')]));
		}
		if (flags && flags.app_usage) {
			ops.push(E('button', { 'class': 'nd-btn nd-b-purple', 'click': ui.createHandlerFn(this, function () { doAppUsage(d); }) },
				[_('App 记录')]));
		}

		var tags = [];
		tags.push(d.online ? tag(_('在线'), 'nd-on') : tag(_('离线'), 'nd-off'));
		if (d.banned) tags.push(tag(_('已封锁'), 'nd-ban'));
		if (d.limit_down > 0 || d.limit_up > 0) tags.push(tag(_('限速'), 'nd-lim'));
		if (d.is_static) tags.push(tag(_('静态'), 'nd-lim'));

		var traffic = null;
		if (flags && flags.traffic) {
			var tot = (parseInt(d.rx_bytes) || 0) + (parseInt(d.tx_bytes) || 0);
			traffic = E('div', { 'style': 'margin-top:3px' }, [
				E('div', { 'class': 'nd-muted' }, [
					_('↓') + ' ' + fmtBytes(d.rx_bytes) + '  ·  ',
					_('↑') + ' ' + fmtBytes(d.tx_bytes)
				]),
				E('div', { 'class': 'nd-bar' }, [E('i', { 'style': 'width:' + Math.min(100, tot / 1048576 * 4) + '%' })])
			]);
		}

		return E('tr', {}, [
			E('td', {}, [
				E('div', { 'class': 'nd-name' }, [d.name || E('span', { 'class': 'nd-unknown' }, [_('未知设备')])]),
				E('div', { 'style': 'margin-top:3px' }, tags)
			]),
			E('td', { 'class': 'nd-mono' }, [(d.ip4 || '-').split(',').join(', ') || '-']),
			E('td', { 'class': 'nd-mono', 'style': 'font-size:11px;word-break:break-all;max-width:180px' },
				[(d.ip6 || '-').split(',').join(', ') || '-']),
			E('td', { 'class': 'nd-mono' }, [d.mac]),
			E('td', {}, [
				E('div', {}, [fmtDur(d.uptime)]),
				E('div', { 'class': 'nd-muted' }, [fmtTime(d.first_seen)]),
				traffic
			]),
			E('td', { 'class': 'nd-mono', 'style': 'font-size:11px' }, [
				(d.limit_down > 0 || d.limit_up > 0)
					? E('div', {}, [_('↓') + ' ' + fmtRate(d.limit_down), E('br'), _('↑') + ' ' + fmtRate(d.limit_up)])
					: E('span', { 'class': 'nd-muted' }, [_('不限速')])
			]),
			E('td', { 'style': 'white-space:nowrap' }, ops)
		]);
	});

	if (!rows.length) {
		rows.push(E('tr', {}, [
			E('td', { 'colspan': 7, 'style': 'padding:24px;text-align:center;color:#a0aec0' },
				[_('没有发现设备')])
		]));
	}

	var on = list.filter(function (d) { return d.online; }).length;
	var ban = list.filter(function (d) { return d.banned; }).length;
	var lim = list.filter(function (d) { return d.limit_down > 0 || d.limit_up > 0; }).length;

	function card(num, lbl, color) {
		return E('div', { 'class': 'nd-card' }, [
			E('div', { 'class': 'num', 'style': color ? 'color:' + color : '' }, [String(num)]),
			E('div', { 'class': 'lbl' }, [lbl])
		]);
	}

	return E('div', { 'class': 'nd-wrap' }, [
		E('div', { 'class': 'nd-hero' }, [
			E('h2', {}, [_('在线设备')]),
			E('div', { 'class': 'sub' }, [
				_('实时掌握局域网设备：IPv4 / IPv6 / MAC / 在线时长 / 上线时间 / 设备名，支持静态地址、踢下线、限速')
			])
		]),
		E('div', { 'class': 'nd-cards' }, [
			card(on,  _('在线设备'), '#38a169'),
			card(list.length, _('设备总数'), '#2b6cb0'),
			card(ban, _('已封锁'), '#dd6b20'),
			card(lim, _('已限速'), '#805ad5'),
			E('div', { 'class': 'nd-card', 'style': 'flex:0 0 auto;display:flex;align-items:center' }, [
				E('button', { 'class': 'nd-btn nd-b-blue', 'click': ui.createHandlerFn(this, reload) }, [_('🔄 刷新')])
			])
		]),
		E('div', { 'class': 'nd-section' }, [
			E('h3', {}, [_('设备列表')]),
			E('div', { 'class': 'body', 'style': 'padding:0' }, [
				E('table', { 'class': 'nd-table' }, [
					E('tr', {}, [
						E('th', {}, [_('设备')]), E('th', {}, [_('IPv4')]), E('th', {}, [_('IPv6')]),
						E('th', {}, [_('MAC')]), E('th', {}, [_('在线时长 / 上线时间')]),
						E('th', {}, [_('限速')]), E('th', {}, [_('操作')])
					])
				].concat(rows))
			])
		])
	]);
}

/* ---------------- 运行环境检测 ---------------- */
function renderCaps(c) {
	if (!c) return null;
	function row(ok, label, hint) {
		return E('div', { 'style': 'display:flex;align-items:center;gap:8px;padding:3px 0' }, [
			E('span', { 'style': 'font-size:15px;width:18px;text-align:center' }, [ok ? '✅' : '⚠️']),
			E('span', { 'style': 'min-width:150px' }, [label]),
			hint ? E('span', { 'class': 'nd-muted' }, [hint]) : null
		]);
	}
	/* 不检测/不提示安装任何包；仅展示运行状态 */
	return E('div', { 'class': 'nd-section' }, [
		E('h3', {}, [_('🔧 运行环境检测')]),
		E('div', { 'class': 'body' }, [
			E('div', { 'class': 'nd-muted', 'style': 'margin-bottom:8px' }, [
				_('仅报告状态，不依赖额外软件包。防火墙使用 fw4/nft；限速有 tc 则用。')
			]),
			row(c.tc, 'tc', _('限速 / 流量统计（有则启用，无则降级）')),
			row(true, 'HTB / u32', _('内核内置，无需安装')),
			row(c.ifb, 'ifb0', _('下行限速（可用时自动创建）')),
			row(c.nft || c.fw4, _('防火墙 fw4 / nftables'), _('踢下线封锁（无 iptables/fw3）')),
			row(c.iw, 'iw', _('WiFi 去关联（踢下线时用）')),
			row(c.dhcp_release, 'dhcp_release', _('踢下线时立刻释放租约')),
			E('div', {
				'style': 'margin-top:12px;padding:8px 12px;background:#f0fff4;border:1px solid #9ae6b4;border-radius:6px'
			}, [_('✅ 无需安装额外软件包，缺组件时功能自动降级')])
		])
	]);
}

/* ---------------- 实验功能开关 ---------------- */
function renderFlags(flags, reload) {
	function sw(key, label, desc) {
		var cb = E('input', { 'type': 'checkbox' });
		cb.checked = !!(flags && flags[key]);
		cb.addEventListener('change', function () {
			var patch = {};
			patch[key] = cb.checked ? '1' : '0';
			return callSetFlags(patch.traffic || (flags && flags.traffic ? '1' : '0'),
			                   patch.app_usage || (flags && flags.app_usage ? '1' : '0'))
				.then(function () { notify(_('开关已更新'), true); reload(); });
		});
		return E('div', { 'class': 'nd-switch' }, [
			cb,
			E('label', { 'style': 'font-weight:600' }, [label]),
			E('span', { 'class': 'nd-tag nd-test' }, [_('测试功能')]),
			E('span', { 'class': 'nd-muted' }, [desc])
		]);
	}

	return E('div', { 'class': 'nd-section' }, [
		E('h3', {}, [_('实验功能'), E('span', { 'class': 'nd-muted', 'style': 'margin-left:8px;font-weight:400' },
			[_('默认关闭 · 数据仅供参考')])]),
		E('div', { 'class': 'nd-body body' }, [
			sw('traffic', _('流量统计'), _('统计每台设备的上行/下行字节数（来自 tc 计数器，重启后从零开始）')),
			sw('app_usage', _('App 使用记录'), _('按目标端口粗分服务类型（HTTPS/DNS/邮件/IoT/推送/流媒体等），无法识别具体 App 名'))
		])
	]);
}

/* ---------------- 使用说明 ---------------- */
function renderHelp(h) {
	var sections = (h && h.sections) ? h.sections : [];
	return E('div', { 'class': 'nd-section nd-help' }, [
		E('h3', {}, [_('📖 使用说明')]),
		E('div', { 'class': 'body' }, sections.map(function (s) {
			return E('div', { 'style': 'margin-bottom:14px' }, [
				E('h4', { 'style': 'margin:0 0 6px;color:#2b6cb0;font-size:13px' }, [s.h]),
				E('ul', { 'style': 'margin:0 0 0 18px;padding:0' }, (s.items || []).map(function (t) {
					return E('li', { 'style': 'line-height:1.8' }, [t]);
				}))
			]);
		}))
	]);
}

/* ---------------- 主视图 ---------------- */
var rootEl = null;

function renderAll(data, flags, help, caps) {
	var el = E('div', {}, [
		renderTable(data, flags, load),
		renderCaps(caps),
		renderFlags(flags, load),
		renderHelp(help)
	]);
	if (rootEl && rootEl.parentNode) rootEl.parentNode.replaceChild(el, rootEl);
	rootEl = el;
}

function load() {
	return Promise.all([
		callStatus().catch(function () { return {}; }),
		callHelp().catch(function () { return {}; }),
		callCaps().catch(function () { return {}; })
	]).then(function (r) {
		var st = r[0] || {};
		var data = st.result || (Array.isArray(st) ? st : []);
		var flags = st.flags || {};
		renderAll(data, flags, r[1] && r[1].result ? r[1].result : r[1],
		          r[2] && r[2].result ? r[2].result : r[2]);
	}).catch(function (e) {
		var msg = (e && e.message) ? e.message : String(e);
		var isObj = /Object not found|-32000/i.test(msg);
		var box = E('div', { 'class': 'nd-section', 'style': 'border-color:#feb2b2' }, [
			E('h3', { 'style': 'background:#fff5f5;color:#c53030' }, [
				isObj ? _('⚠️ ubus 上找不到 netdevices 对象') : _('读取失败')
			]),
			E('div', { 'class': 'body' }, [
				E('div', { 'class': 'nd-mono', 'style': 'margin-bottom:10px' }, [msg]),
				isObj ? E('ol', { 'style': 'margin-left:20px;line-height:1.9' }, [
					E('li', {}, [_('重启 rpcd：'), E('code', {}, ['/etc/init.d/rpcd restart'])]),
					E('li', {}, [_('检查权限：'), E('code', {}, ['chmod 755 /usr/libexec/rpcd/netdevices'])]),
					E('li', {}, [_('CRLF 会导致 sh 无法执行，必要时：'),
						E('code', {}, ['dos2unix /usr/libexec/rpcd/netdevices'])]),
					E('li', {}, [_('手动验证：'), E('code', {}, ['/usr/libexec/rpcd/netdevices list'])])
				]) : null
			])
		]);
		if (rootEl && rootEl.parentNode) rootEl.parentNode.replaceChild(box, rootEl);
		rootEl = box;
	});
}

return view.extend({
	handleSave: null, handleSaveApply: null, handleReset: null,

	render: function () {
		injectCss();
		rootEl = E('div', { 'class': 'nd-wrap' }, [
			E('div', { 'class': 'nd-hero' }, [
				E('h2', {}, [_('在线设备')]),
				E('div', { 'class': 'sub' }, [_('正在加载…')])
			])
		]);
		if (autoTimer) clearInterval(autoTimer);
		autoTimer = setInterval(load, 30000);
		load();
		return rootEl;
	},

	addFooter: function () {
		if (autoTimer) { clearInterval(autoTimer); autoTimer = null; }
	}
});
