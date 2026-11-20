-- OMP 会话历史侧边栏：每个活动标签页使用一个原生画布面板。
local TITLE = "OMP History"
local DEFAULT_PAGE_SIZE = 8
local tern_executable = tern.getenv("TERN_EXE")
if not tern_executable or tern_executable == "" then
	local app_executable = "/Applications/Tern.app/Contents/MacOS/tern"
	tern_executable = if tern.runtime.os == "macos" and tern.fs.exists(app_executable) then app_executable else "tern"
end
local rows = {}
local filtered = {}
local query = ""
local panes = {}
local sidebar_tabs = {}
local loading = false
local sizing = false
local next_size_check = 0
local error_text = nil
local opening = false
-- 尺寸改为事件驱动：只有分屏/关窗/切焦点才重新量一次。
local size_dirty = true
-- 每个侧栏上次真正发出的签名，避免同一帧内容重复 set。
local last_sig = {}
-- 每个标签页里由本插件拉起的 omp 窗口，恢复新会话前先回收。
local chat_panes = {}

-- 转义传给终端 shell 的单个参数。
local function shell_quote(value)
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

-- 为每个侧边栏保留独立的页码与可见行数。
local function pane_state(pane)
	if not pane then return { page = 1, size = DEFAULT_PAGE_SIZE } end
	if not panes[pane] then panes[pane] = { page = 1, size = DEFAULT_PAGE_SIZE } end
	return panes[pane]
end

-- 对搜索条件应用过滤，保留原始时间排序。
local function filter_rows()
	filtered = {}
	local needle = string.lower(query)
	for _, row in rows do
		-- 只剥控制字符；Nerd 图标是多字节 UTF-8，字节级 gsub 无法安全剥离，保留即可。
		local clean_title = string.gsub(row.title or "", "[%c]+", " ")
		local haystack = string.lower(clean_title .. " " .. (row.cwd or "") .. " " .. (row.id or "") .. " " .. (row.path or ""))
		if needle == "" or string.find(haystack, needle, 1, true) then
			table.insert(filtered, row)
		end
	end
end

-- 人类友好的相对时间：几分钟前/几小时前/几天前，超过一周用日期。
local function relative_time(ts)
	local diff = os.time() - ts
	if diff < 0 then diff = 0 end
	if diff < 60 then return "刚刚" end
	if diff < 3600 then return math.floor(diff / 60) .. " 分钟前" end
	if diff < 86400 then return math.floor(diff / 3600) .. " 小时前" end
	if diff < 604800 then return math.floor(diff / 86400) .. " 天前" end
	return os.date("%m-%d", ts)
end

-- 构建当前窗格的会话卡片和固定在底部的分页栏。
local function view(pane)
	local ui = tern.ui
	local state = pane_state(pane)
	local pages = math.max(1, math.ceil(#filtered / state.size))
	state.page = math.max(1, math.min(state.page, pages))
	local cards = {}
	if error_text then
		table.insert(cards, ui.card("读取失败", {
			ui.text(error_text),
			ui.text("检查会话目录：$PI_CODING_AGENT_DIR/sessions 或 ~/.omp/agent/sessions"),
		}, { tone = "error", icon = "warning" }))
	elseif loading and #rows == 0 then
		table.insert(cards, ui.text("正在读取会话…"))
	elseif #filtered == 0 then
		if query == "" then
			table.insert(cards, ui.card("没有保存的会话", {
				ui.text("运行一次 omp 后会自动出现在这里"),
			}, { tone = "muted", icon = "history" }))
		else
			table.insert(cards, ui.card("没有匹配的会话", {
				ui.text("搜索词：" .. query),
				ui.text("可搜索标题、目录或会话 ID"),
			}, { tone = "muted", icon = "search" }))
		end
	end
	local first = (state.page - 1) * state.size + 1
	local last = math.min(state.page * state.size, #filtered)
	local now = os.time()
	local today = os.date("%Y-%m-%d", now)
	local yesterday = os.date("%Y-%m-%d", now - (tonumber(os.date("%H", now)) + 12) * 3600)
	for i = first, last do
		local row = filtered[i]
		local title = string.gsub(row.title, "[%c]+", " ")
		local cwd = if row.cwd ~= "" then (string.match(row.cwd, "([^/]+)$") or string.match(row.cwd, "([^\\]+)$") or row.cwd) else "未知目录"
		local day = os.date("%Y-%m-%d", row.updated)
		local short_id = string.sub(row.id, 1, 8)
		local rel = relative_time(row.updated)
		local day_label = if day == today then "今天" elseif day == yesterday then "昨天" else os.date("%m-%d", row.updated)
		table.insert(cards, ui.el("button", {
			key = "chat_" .. row.id,
			class = "omp-history-card",
			title = title .. "\n" .. row.cwd .. "\n" .. row.id,
			actions = { click = "chat:" .. row.id },
		}, {
			ui.el("div", { class = "omp-history-title", text = title }),
			ui.node("row", { gap = "xs", class = "omp-history-meta" }, {
				ui.badge(rel, if day == today then "accent" else "muted"),
				ui.el("span", { text = day_label }),
				ui.el("span", { text = "·" }),
				ui.el("span", { text = cwd }),
				ui.el("span", { text = "·" }),
				ui.el("span", { text = short_id }),
			}),
		}))
	end
	local search_label = if query == "" then "搜索" else "搜索: " .. query
	local main = ui.node("col", { gap = "none" }, {
		ui.node("row", { gap = "sm", justify = "end" }, {
			ui.button(search_label, { icon = "search", title = "搜索标题、目录或会话 ID", size = "sm", actions = { click = "search" } }),
			ui.button("刷新", { icon = "repeat", title = "立即刷新会话索引", size = "sm", actions = { click = "refresh" } }),
		}),
		ui.el("div", { class = "omp-history-list" }, cards),
	})
	local dock = ui.node("col", { gap = "none" }, {
		ui.el("div", { class = "omp-history-footer" }, {
			ui.node("row", { gap = "xs" }, {
				ui.button("", { icon = "arrow-left", title = "上一页", size = "sm", disabled = state.page == 1, actions = { click = "prev" } }),
				ui.text(state.page .. " / " .. pages),
				ui.button("", { icon = "arrow-right", title = "下一页", size = "sm", disabled = state.page == pages, actions = { click = "next" } }),
			}),
			ui.el("div", { class = "omp-history-count", text = if #filtered == 0 then "0 个会话" else ("第 " .. first .. "–" .. last .. " / 共 " .. #filtered .. " 个") }),
		}),
	})
	return main, dock
end

-- 将当前列表同步到插件拥有的所有侧边栏。
-- 签名必须能吃出“可见内容”的变化：标题被 /rename 或索引刷新改写时，
-- id 集合往往不变，只有 title/path/updated 变了，否则刷新按钮会静默失效。
local function content_sig(state)
	local parts = {
		tostring(#filtered), query, tostring(error_text), tostring(loading),
		tostring(state.page), tostring(state.size),
	}
	local first = (state.page - 1) * state.size + 1
	local last = math.min(state.page * state.size, #filtered)
	for i = first, last do
		local row = filtered[i]
		parts[#parts + 1] = row.id
		parts[#parts + 1] = row.title
		parts[#parts + 1] = row.cwd
		parts[#parts + 1] = tostring(row.updated)
	end
	return table.concat(parts, "\1")
end

local function redraw(cx)
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			sidebar_tabs[canvas.pane] = cx.session:tab_of(canvas.pane)
			local state = pane_state(canvas.pane)
			local sig = content_sig(state)
			if last_sig[canvas.pane] ~= sig then
				last_sig[canvas.pane] = sig
				local main, dock = view(canvas.pane)
				-- 超节点上限时 canvas:set 会抛错，别让一次失败打断整轮重绘。
				pcall(cx.canvas.set, cx.canvas, canvas.pane, { view = main, dock = dock })
			end
		end
	end
end

-- 从 Tern 的窗格网格高度计算每页数量，尺寸变化时保留当前首条会话。
local function update_sizes(cx)
	if sizing then return end
	local owned = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then owned[canvas.pane] = true end
	end
	if not next(owned) then return end
	sizing = true
	tern.process.run({ tern_executable, "ls", "--json" }, { timeout_ms = 5000 }, function(result, next_cx)
		sizing = false
		if not next_cx or result.status ~= 0 then return end
		local ok, data = pcall(tern.json.decode, result.stdout)
		if not ok or type(data) ~= "table" or type(data.sessions) ~= "table" then return end
		local changed = false
		for _, session in data.sessions do
			for _, tab in session.tabs or {} do
				for _, block in tab.blocks or {} do
					if owned[block.id] and type(block.rows) == "number" and block.rows > 0 then
						local state = pane_state(block.id)
						-- 每张卡约 10 个节点，canvas 硬上限 2000 节点：300 行会直接超限。
						local size = math.max(1, math.min(120, math.floor((block.rows - 5) / 3.4)))
						if size ~= state.size then
							local first = (state.page - 1) * state.size
							state.page = math.floor(first / size) + 1
							state.size = size
							changed = true
						end
					end
				end
			end
		end
		if changed then redraw(next_cx) end
	end)
end

-- 在后台读取索引，避免大目录扫描阻塞 Tern 窗口。
local function refresh(cx)
	if loading then return end
	loading = true
	tern.process.run({ "python", tern.plugin.dir .. "/sessions.py" }, { timeout_ms = 30000 }, function(result, next_cx)
		loading = false
		if not next_cx then return end
		if result.status ~= 0 then
			error_text = if result.stderr ~= "" then result.stderr else "索引程序运行失败"
		else
			local ok, data = pcall(tern.json.decode, result.stdout)
			if ok and type(data) == "table" then
				rows = data
				error_text = nil
				filter_rows()
			else
				error_text = "索引结果无效"
			end
		end
		redraw(next_cx)
	end)
end

-- 为当前标签页挂载侧边栏，已有面板时保留现有布局。
local function ensure_sidebar(cx)
	if tern.kv.get("visible") ~= true or opening then return end
	local focused = cx.session:focused()
	local tab = if focused then cx.session:tab_of(focused) else nil
	if not tab then return end
	-- 先收集当前 tab 下的所有 pane；用 PaneInfo.tab 判断，避免 tab_of 在 canvas 刚
	-- 创建、尚未注册到 session 树时返回 nil 而重复开窗。
	local panes_in_tab = {}
	for _, info in ipairs(cx.session:panes()) do
		if info.tab == tab then
			panes_in_tab[info.pane] = true
			if info.program == "tern.canvas" and info.title == TITLE then
				sidebar_tabs[info.pane] = tab
				return
			end
		end
	end
	-- 再同步一遍 canvas owner 记录（tab_of 此时通常已可用）。
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			if panes_in_tab[canvas.pane] or cx.session:tab_of(canvas.pane) == tab then
				sidebar_tabs[canvas.pane] = tab
				return
			end
		end
	end
	opening = true
	local main, dock = view()
	local pane, err = cx.canvas:open({
		title = TITLE,
		about = "浏览、搜索并恢复本地 OMP 会话。",
		view = main,
		dock = dock,
		how = "beside",
		target = focused,
		dir = "left",
		ratio = 0.25,
		focus = false,
	})
	opening = false
	if pane then
		sidebar_tabs[pane] = tab
	else
		cx:toast("error", "无法打开 OMP 历史侧边栏", tostring(err))
	end
end

-- 隐藏所有历史面板，手动关闭时跳过已经关闭的窗格。
local function hide_sidebars(cx, closed_pane)
	tern.kv.set("visible", false)
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE and canvas.pane ~= closed_pane then
			cx.layout:close(canvas.pane)
		end
	end
end

-- 首次升级时隐藏旧版已打开的侧边栏，之后保留用户的切换状态。
local function initialize_visibility(cx)
	if tern.kv.get("default_hidden_v1") == true then return end
	tern.kv.set("visible", false)
	tern.kv.set("default_hidden_v1", true)
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			cx.layout:close(canvas.pane)
		end
	end
end

-- 保留现有组件设置，添加供窗口右上角显示的历史入口。
local function ensure_toolbar_widget(cx)
	local widgets = cx.settings:get("widgets") or {}
	for _, widget in widgets do
		if widget.id == "omp-history/toggle" then return end
	end
	table.insert(widgets, { id = "omp-history/toggle" })
	cx.settings:set("widgets", widgets)
end

-- 找到当前标签最右侧的实际内容窗格，避免把侧边栏再次拆开。
local function rightmost(tree, sidebar)
	if not tree then return nil end
	if tree.pane then return if tree.pane ~= sidebar then tree.pane else nil end
	return rightmost(tree[2], sidebar) or rightmost(tree[1], sidebar)
end

-- 根据会话文件和原工作目录在当前标签右侧分屏恢复会话。
local function open_chat(cx, row, sidebar)
	local origin = sidebar or cx.session:focused()
	local tab = if origin then cx.session:tab_of(origin) else nil
	local layout = if tab then cx.session:layout(tab) else nil
	local target = if layout then rightmost(layout.root, sidebar) else nil
	-- 同一标签页里上一个由本插件拉起的 omp 先关掉，避免叠加几百 MB。
	if tab and chat_panes[tab] then
		pcall(cx.layout.close, cx.layout, chat_panes[tab])
		chat_panes[tab] = nil
	end
	local launch = { command = "omp --resume " .. shell_quote(row.path) }
	if row.cwd ~= "" then launch.cwd = row.cwd end
	if not target then
		cx:toast("error", "无法恢复会话", row.title)
		return
	end
	local opened = cx.layout:split(target, "right", launch)
	if not opened then
		cx:toast("error", "无法恢复会话", row.title)
		return
	end
	if tab then chat_panes[tab] = opened end
end

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= tern.plugin.id then return nil end
	local id = string.match(ev.act, "^chat:(.+)$")
	if id then
		for _, row in rows do
			if row.id == id then
				open_chat(cx, row, ev.pane)
				break
			end
		end
	elseif ev.act == "search" then
		cx:prompt({ value = query, placeholder = "搜索标题、目录或会话 ID", action = "search" }):next(function(value, err, next_cx)
			if not next_cx then return end
			if err then next_cx:toast("error", "搜索失败", err) return end
			if value ~= nil then
				query = value
				for _, state in panes do state.page = 1 end
				filter_rows()
				redraw(next_cx)
			end
		end)
	elseif ev.act == "refresh" then
		refresh(cx)
	elseif ev.act == "prev" then
		local state = pane_state(ev.pane)
		state.page = math.max(1, state.page - 1)
		redraw(cx)
	elseif ev.act == "next" then
		local state = pane_state(ev.pane)
		state.page = math.min(math.max(1, math.ceil(#filtered / state.size)), state.page + 1)
		redraw(cx)
	else
		return nil
	end
	return true
end)

tern.command({
	id = "browse",
	title = "OMP History: search and resume",
	icon = "history",
	run = function(cx)
		if #rows == 0 then
			cx:toast("info", if loading then "正在读取 OMP 会话" else "没有可用的 OMP 会话", error_text)
			return
		end
		local items = {}
		for _, row in rows do
			table.insert(items, { label = row.title, detail = row.cwd, row = row })
		end
		cx:pick({ items = items, placeholder = "搜索 OMP 会话", action = "resume" }):next(function(item, err, next_cx)
			if not next_cx then return end
			if err then
				next_cx:toast("error", "无法选择 OMP 会话", err)
			elseif item then
				open_chat(next_cx, item.row)
			end
		end)
	end,
})

tern.command({
	id = "toggle",
	title = "OMP History: toggle sidebar",
	icon = "history",
	run = function(cx)
		if tern.kv.get("visible") ~= true then
			tern.kv.set("visible", true)
			ensure_sidebar(cx)
			refresh(cx)
		else
			hide_sidebars(cx)
		end
	end,
})
tern.bind("cmd+alt+shift+h", "plugin.omp-history.toggle")

-- Widget 点击直接走正常 toggle；同 tab 去重由 tick 保证。
local function toggle_from_widget(cx)
	if tern.kv.get("visible") ~= true then
		tern.kv.set("visible", true)
		ensure_sidebar(cx)
		refresh(cx)
	else
		hide_sidebars(cx)
	end
end

tern.command({
	id = "toggle_widget",
	title = "OMP History: toggle (widget)",
	run = function(cx) toggle_from_widget(cx) end,
})

tern.chrome.widget("toggle", {
	name = "OMP History",
	description = "显示或隐藏 OMP 会话历史",
	icon = "history",
	render = function(_pane)
		return { text = "", title = "显示/隐藏 OMP 会话历史", command = "plugin.omp-history.toggle_widget" }
	end,
})

-- 定期在新标签上挂载面板，并清理只剩侧边栏的标签。
local function tick(cx)
	tern.timer(1000, tick)
	if not cx then return end
	-- 去重：同一 tab 只允许一个 OMP History canvas，多余的关掉。
	local seen_tab = {}
	local pane_tab = {}
	local closed_any = false
	for _, info in ipairs(cx.session:panes()) do pane_tab[info.pane] = info.tab end
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			local tab = pane_tab[canvas.pane] or cx.session:tab_of(canvas.pane)
			sidebar_tabs[canvas.pane] = tab
			if tab then
				if seen_tab[tab] then
					sidebar_tabs[canvas.pane] = nil
					panes[canvas.pane] = nil
					last_sig[canvas.pane] = nil
					cx.layout:close(canvas.pane)
					closed_any = true
				else
					seen_tab[tab] = canvas.pane
				end
			end
			local count = 0
			for _, pane in ipairs(cx.session:panes()) do
				if pane.tab == tab then count += 1 end
			end
			if tab and count == 1 then
				sidebar_tabs[canvas.pane] = nil
				last_sig[canvas.pane] = nil
				cx.layout:close(canvas.pane)
				closed_any = true
			end
		end
	end
	-- 刚关掉的这一 tick 别立刻重开，否则形成每秒开关环。
	if not closed_any then ensure_sidebar(cx) end
	if size_dirty and tern.now() >= next_size_check then
		size_dirty = false
		next_size_check = tern.now() + 8000
		update_sizes(cx)
	end
end

-- 布局变化才需要重新量高度，不再靠每 2 秒轮询。
local function mark_size_dirty() size_dirty = true end
tern.on("pane_created", mark_size_dirty)
tern.on("pane_closed", mark_size_dirty)
tern.on("tab_created", mark_size_dirty)
tern.on("focus", mark_size_dirty)

-- 关闭整个标签时不改变其他标签的历史侧边栏显示状态。
tern.on("tab_closed", function(ev)
	for pane, tab in sidebar_tabs do
		if tab == ev.tab then sidebar_tabs[pane] = nil end
	end
end)

tern.on("pane_closed", function(ev, cx)
	local was_sidebar = sidebar_tabs[ev.pane] ~= nil
	sidebar_tabs[ev.pane] = nil
	panes[ev.pane] = nil
	last_sig[ev.pane] = nil
	for tab, pane in chat_panes do
		if pane == ev.pane then chat_panes[tab] = nil end
	end
	if was_sidebar and tern.kv.get("visible") == true then
		hide_sidebars(cx, ev.pane)
	end
end)

-- 定期刷新历史，手动刷新和搜索不必等待定时器。
local function refresh_tick(cx)
	tern.timer(30000, refresh_tick)
	if cx then refresh(cx) end
end

tern.on("window_start", function(cx)
	initialize_visibility(cx)
	ensure_toolbar_widget(cx)
	ensure_sidebar(cx)
	refresh(cx)
end)
-- 插件重载不会重新触发 window_start，需要主动恢复索引。
tern.timer(100, function(cx)
	if cx then
		initialize_visibility(cx)
		ensure_toolbar_widget(cx)
		refresh(cx)
	end
end)
tern.timer(1000, tick)
tern.timer(30000, refresh_tick)
