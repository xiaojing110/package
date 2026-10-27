'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({
	object: 'netdevices',
	method: 'status',
	expect: { 'result': [] }
});

var callSetStatic = rpc.declare({
	object: 'netdevices',
	method: 'set_static',
	params: ['mac', 'ip', 'name'],
	expect: { 'result': true }
});

var callRemoveStatic = rpc.declare({
	object: 'netdevices',
	method: 'remove_static',
	params: ['mac'],
	expect: { 'result': true }
});

var autoTimer = null;

function fmtDur(s) {
	s = Math.max(0, parseInt(s) || 0);
	if (s < 60) return _('%d 秒').format(s);
	var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600),
	    m = Math.floor((s % 3600) / 60);
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
	       ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function stateBadge(st, online) {
	var color = online ? '#2ecc71' : '#e74c3c';
	var txt = online ? _('在线') : _('离线');
	if (st) txt += ' (' + st + ')';
	return E('span', {
		'style': 'display:inline-block;padding:2px 8px;border-radius:10px;' +
		         'background:' + color + '22;color:' + color + ';font-size:12px;'
	}, [txt]);
}

function showStaticModal(mac, curIp, curName, isStatic, onDone) {
	var ipEl = E('input', {
		'type': 'text', 'class': 'cbi-input-text',
		'value': curIp || '', 'style': 'width:100%',
		'placeholder': '192.168.1.100'
	});
	var nameEl = E('input', {
		'type': 'text', 'class': 'cbi-input-text',
		'value': curName || '', 'style': 'width:100%',
		'placeholder': _('设备名（可选）')
	});

	var body = E('div', { 'class': 'cbi-value' }, [
		E('div', { 'style': 'margin-bottom:12px' }, [
			E('label', {}, [_('MAC 地址')]),
			E('div', { 'style': 'font-family:monospace;margin-top:4px' }, [mac])
		]),
		E('div', { 'style': 'margin-bottom:12px' }, [
			E('label', {}, [_('IPv4 静态地址')]),
			E('div', { 'style': 'margin-top:4px' }, [ipEl])
		]),
		E('div', { 'style': 'margin-bottom:8px' }, [
			E('label', {}, [_('设备名')]),
			E('div', { 'style': 'margin-top:4px' }, [nameEl])
		])
	]);

	ui.showModal(_('设置静态地址'), body, [
		{
			'label': isStatic ? _('更新') : _('保存'),
			'click': ui.createHandlerFn(this, function () {
				var ip = ipEl.value.trim();
				if (!ip) {
					ui.addNotification(null, E('p', {}, _('请输入 IPv4 地址')), 'warning');
					return;
				}
				return callSetStatic(mac, ip, nameEl.value.trim()).then(function () {
					ui.hideModal();
					ui.addNotification(null, E('p', {}, _('静态地址已保存')), 'info');
					if (onDone) onDone();
				}).catch(function (e) {
					ui.addNotification(null, E('p', {}, _('保存失败: ') + e.message), 'error');
				});
			})
		},
		{ 'label': _('取消'), 'click': ui.hideModal }
	]);
}

function renderTable(data) {
	var rows = [];
	var list = Array.isArray(data) ? data : [];

	list.sort(function (a, b) {
		if (a.online !== b.online) return a.online ? -1 : 1;
		return (a.name || '').localeCompare(b.name || '');
	});

	list.forEach(function (d) {
		var ops = [];

		ops.push(E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'style': 'margin-right:6px;padding:2px 10px;font-size:12px;',
			'click': ui.createHandlerFn(this, function () {
				showStaticModal(d.mac, (d.ip4 || '').split(',')[0], d.name, d.is_static, load);
			})
		}, [d.is_static ? _('修改静态地址') : _('设置静态地址')]));

		if (d.is_static) {
			ops.push(E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'style': 'padding:2px 10px;font-size:12px;',
				'click': ui.createHandlerFn(this, function () {
					return callRemoveStatic(d.mac).then(function () {
						ui.addNotification(null, E('p', {}, _('已移除静态地址')), 'info');
						load();
					});
				})
			}, [_('移除')]));
		}

		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'style': 'font-weight:bold' }, [
				d.name || E('span', { 'style': 'color:#999' }, [_('未知设备')])
			]),
			E('td', { 'class': 'td', 'style': 'font-family:monospace' }, [
				(d.ip4 || '-').split(',').join(', ')
			]),
			E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:11px;word-break:break-all' }, [
				(d.ip6 || '-').split(',').join(', ')
			]),
			E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:12px' }, [d.mac || '-']),
			E('td', { 'class': 'td' }, [fmtDur(d.uptime)]),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, [fmtTime(d.first_seen)]),
			E('td', { 'class': 'td' }, [stateBadge(d.state, d.online)]),
			E('td', { 'class': 'td', 'style': 'white-space:nowrap' }, ops)
		]));
	});

	if (!rows.length) {
		rows.push(E('tr', { 'class': 'tr placeholder' }, [
			E('td', { 'class': 'td', 'colspan': 8 }, [_('没有发现设备')])
		]));
	}

	var onlineCount = list.filter(function (d) { return d.online; }).length;
	var staticCount = list.filter(function (d) { return d.is_static; }).length;

	return E('div', {}, [
		E('div', {
			'style': 'margin:10px 0;display:flex;gap:20px;align-items:center;flex-wrap:wrap'
		}, [
			E('span', {}, [_('在线设备') + ': ']),
			E('b', { 'style': 'color:#2ecc71;font-size:18px' }, [String(onlineCount)]),
			E('span', {}, [_('设备总数') + ': ']),
			E('b', { 'style': 'font-size:18px' }, [String(list.length)]),
			E('span', {}, [_('静态地址') + ': ']),
			E('b', { 'style': 'color:#3498db;font-size:18px' }, [String(staticCount)]),
			E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'style': 'margin-left:auto;padding:3px 14px;',
				'click': ui.createHandlerFn(this, load)
			}, [_('刷新')])
		]),
		E('div', { 'class': 'table-wrapper' }, [
			E('table', { 'class': 'table cbi-section-table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, [_('设备名')]),
					E('th', { 'class': 'th' }, [_('IPv4 地址')]),
					E('th', { 'class': 'th' }, [_('IPv6 地址')]),
					E('th', { 'class': 'th' }, [_('MAC 地址')]),
					E('th', { 'class': 'th' }, [_('在线时长')]),
					E('th', { 'class': 'th' }, [_('上线时间')]),
					E('th', { 'class': 'th' }, [_('状态')]),
					E('th', { 'class': 'th' }, [_('操作')])
				])
			].concat(rows))
		])
	]);
}

var viewEl = null;

function load() {
	return callStatus().then(function (res) {
		var list = (res && res.result) ? res.result : (Array.isArray(res) ? res : []);
		var el = renderTable(list);
		if (viewEl && viewEl.parentNode) {
			viewEl.parentNode.replaceChild(el, viewEl);
		}
		viewEl = el;
	}).catch(function (e) {
		if (viewEl && viewEl.parentNode) {
			viewEl.parentNode.replaceChild(
				E('div', { 'class': 'alert-message warning' }, [_('读取失败: ') + e.message]), viewEl);
		}
	});
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	render: function () {
		viewEl = renderTable([]);
		var root = E('div', {}, [
			E('h2', {}, [_('在线设备')]),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('显示局域网在线设备的 IPv4 / IPv6 地址、MAC、在线时长与上线时间，可直接设置 DHCP 静态地址。'),
				E('br'),
				E('small', { 'style': 'color:#888' }, [
					_('数据来源：ARP/NDP 邻居表、dnsmasq 租约、/etc/config/dhcp。设备名优先取 DHCP 主机名。')
				])
			]),
			viewEl
		]);

		// 自动刷新
		if (autoTimer) clearInterval(autoTimer);
		autoTimer = setInterval(load, 30000);

		load();
		return root;
	},

	addFooter: function () {
		if (autoTimer) { clearInterval(autoTimer); autoTimer = null; }
	}
});
