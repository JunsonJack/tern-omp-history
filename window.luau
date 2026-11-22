-- OMP 会话历史侧边栏：每个活动标签页使用一个原生画布面板。
local TITLE = "OMP History"
local rows = {}
local filtered = {}
local query = ""
local loading = false
local error_text = nil
local opening = false
-- 归档视图开关与归档会话集合（kv 持久化）。
local view_archived = false
local archived_sessions = {}
-- 画布超节点会 set 失败：每卡约 10 节点、上限 2000，留余量截断。
local MAX_VISIBLE_CARDS = 150
local last_sig = {}
local sidebar_tabs = {}
-- 每个标签页里由本插件拉起的 omp 窗口，恢复新会话前先回收。
local chat_panes = {}
-- sidebar_tabs 里暂时没出现在宿主列表中的 pane，以及首次发现缺失的时间。
-- canvas 刚 open 完、还没注册进 session 树时宿主列表看不到它，先留着记录。
local missing_since = {}
-- 已探明的可用 python 命令；记住后避免每次 refresh 都先 spawn 一次失败的 python。
local python_cmd = nil

-- 转义传给终端 shell 的单个参数。Tern 的窗格 shell 取自用户的登录 shell
-- （Windows 上可能是 PowerShell 或 cmd.exe，POSIX 上是 bash/zsh/fish），
-- 不能只按操作系统判断：这里从实际承载恢复会话的窗格读取 program 再决定。
-- 参数本身是 OMP 会话文件路径，不含换行，按单引号 / 双引号规则分别处理。
local function shell_quote(value, shell)
	local name = string.lower(tostring(shell or ""))
	local powershell = string.find(name, "powershell", 1, true) or string.find(name, "pwsh", 1, true)
	if powershell then
		-- PowerShell：单引号内两个连续单引号表示一个单引号。
		return "'" .. string.gsub(value, "'", "''") .. "'"
	end
	if string.find(name, "cmd", 1, true) then
		-- cmd.exe：只认双引号；路径里不含双引号，直接包住即可。
		return '"' .. value .. '"'
	end
	-- POSIX shell：单引号内用 '\'' 折行插入一个单引号。
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

-- 判断窗格使用的 shell：优先取实际目标窗格的 program，其次当前聚焦窗格，
-- 都没有时退回按操作系统猜测（cmd.exe 是 Windows 上唯一需要双引号的分支）。
local function shell_for_pane(cx, pane)
	local programs = {}
	for _, p in ipairs(cx.session:panes()) do
		programs[p.pane] = p.program
	end
	local program = pane and programs[pane] or nil
	if not program then
		local focused = cx.session:focused()
		program = focused and programs[focused] or nil
	end
	if not program and tern.runtime.os == "windows" then return "cmd.exe" end
	return program or ""
end

-- 活着的 timer 句柄：递归 timer 每次触发都会产生新句柄，
-- 所以登记表按名字覆盖，unload 时统一取消，避免重载后旧 VM 的定时器变成孤儿。
local timer_slots = {}
local unloading = false

local function every(name, ms, fn)
	local slot = { ms = ms, fn = fn }
	timer_slots[name] = slot
	local function arm()
		slot.handle = tern.timer(ms, function(cx)
			if unloading or timer_slots[name] ~= slot then return end
			-- 先重新挂载再执行，fn 抛错也不会让定时器就此停摆。
			arm()
			fn(cx)
		end)
	end
	arm()
	return slot
end

-- 归档会话集合：kv 存 { [session_id] = true }。会话文件本体不动，
-- --resume 不受影响；索引里已消失的 id 渲染时自然过滤，无残影。
local function load_archived()
	archived_sessions = {}
	local saved = tern.kv.get("archived_sessions")
	if type(saved) ~= "table" then return end
	for id in saved do archived_sessions[tostring(id)] = true end
end

local function save_archived()
	local saved = {}
	for id in archived_sessions do saved[id] = true end
	tern.kv.set("archived_sessions", saved)
end

-- build_groups 的失效式缓存：输入只可能是 rows/filtered/archived/collapsed，
-- 任何一处变动都走下面对应的失效函数，避免 redraw×canvas、content_sig、view
-- 在一轮里把同样的分组排序算上好几遍。
-- 注意：必须声明在 filter_rows 之前（Luau 词法作用域，local 函数先声明才可见）。
local groups_cache = nil

local function invalidate_groups()
	groups_cache = nil
end

-- 对搜索条件应用过滤，保留原始时间排序。过滤集跟随当前视图：
-- 主视图取未归档会话，归档视图取已归档会话。
local function filter_rows()
	filtered = {}
	-- filtered 是 build_groups 的输入，重过滤后旧分组必须作废。
	invalidate_groups()
	local needle = string.lower(query)
	for _, row in rows do
		local is_archived = archived_sessions[tostring(row.id or "")] == true
		if is_archived == view_archived then
			-- 只剥控制字符；Nerd 图标是多字节 UTF-8，字节级 gsub 无法安全剥离，保留即可。
			local clean_title = string.gsub(row.title or "", "[%c]+", " ")
			local haystack = string.lower(clean_title .. " " .. (row.cwd or "") .. " " .. (row.id or "") .. " " .. (row.path or ""))
			if needle == "" or string.find(haystack, needle, 1, true) then
				table.insert(filtered, row)
			end
		end
	end
end

-- 已归档会话总数（与搜索词无关，用于工具栏徽标）。
local function archived_count()
	local n = 0
	for _, row in rows do
		if archived_sessions[tostring(row.id or "")] then n = n + 1 end
	end
	return n
end

-- 项目分组状态：按 cwd 全路径折叠。kv 持久化，跨插件重载保留。
local collapsed_projects = {}

local function load_collapsed()
	collapsed_projects = {}
	invalidate_groups()
	local saved = tern.kv.get("collapsed_projects")
	if type(saved) ~= "table" then return end
	for key in saved do collapsed_projects[key] = true end
end

local function save_collapsed()
	local saved = {}
	for key in collapsed_projects do saved[key] = true end
	tern.kv.set("collapsed_projects", saved)
end

-- kv 跨 VM 共享，但 Lua 表只在启动时读一次；另一个窗口改了归档/折叠状态时
-- 本窗口的视图会一直是旧的。每次刷新索引前重读这两个集合，保证多窗口一致。
local function sync_state_from_kv()
	load_archived()
	load_collapsed()
end

local function project_name(cwd)
	if cwd == "" then return "未知目录" end
	return string.match(cwd, "([^/\\]+)[/\\]?$") or cwd
end

-- 把 filtered 按 cwd 分组：组内 mtime 降序，组间按组内最新会话降序，
-- 最近活跃的项目在最上面。空 cwd 归入 "" 组沉底。
-- rows 本身已按 updated 降序，组内顺序直接沿用；组间用首条（最新）比较。
local function build_groups()
	if groups_cache then return groups_cache end
	local order = {}
	local groups = {}
	for _, row in filtered do
		local key = tostring(row.cwd or "")
		local group = groups[key]
		if not group then
			group = { key = key, name = project_name(key), rows = {} }
			groups[key] = group
			table.insert(order, group)
		end
		table.insert(group.rows, row)
	end
	table.sort(order, function(a, b)
		-- 空目录组沉底；其余按组内最新会话时间比较。
		local a_empty = a.key == ""
		local b_empty = b.key == ""
		if a_empty ~= b_empty then return b_empty end
		return a.rows[1].updated > b.rows[1].updated
	end)
	groups_cache = order
	return order
end

-- 折叠视图下把组展开成“组头 + 会话卡”的渲染序列。返回 seq 中每项
-- { kind = "group"|"chat", group = group, row = row }。
-- 折叠组的组头必须保留，否则没有可点击的入口重新展开。
local function flatten_groups(groups)
	local seq = {}
	for _, group in groups do
		table.insert(seq, { kind = "group", group = group })
		if not collapsed_projects[group.key] then
			for _, row in group.rows do
				table.insert(seq, { kind = "chat", group = group, row = row })
			end
		end
	end
	return seq
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

-- 构建当前视图的会话卡片和固定在底部的计数条。
local function view()
	local ui = tern.ui
	-- 主视图按项目分组；归档视图平铺（归档是时间维度的事，不按项目分组）。
	local grouped = query == "" and not view_archived
	local total_cards = #filtered
	local cards = {}
	if error_text then
		table.insert(cards, ui.card("读取失败", {
			ui.text(error_text),
			ui.text("检查会话目录：$PI_CODING_AGENT_DIR/sessions 或 ~/.omp/agent/sessions"),
		}, { tone = "error", icon = "warning" }))
	elseif loading and #rows == 0 then
		table.insert(cards, ui.text("正在读取会话…"))
	elseif total_cards == 0 then
		if view_archived then
			table.insert(cards, ui.card("没有已归档的会话", {
				ui.text("在主列表卡片上点归档按钮，会话会出现在这里"),
			}, { tone = "muted", icon = "box-archive" }))
		elseif query == "" then
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
	local now = os.time()
	-- 按日历日往前推一天：原来用 now - (小时+12)*3600 在凌晨会把前天算成昨天。
	local today_t = os.date("*t", now)
	local yesterday_ts = os.time({
		year = today_t.year, month = today_t.month, day = today_t.day - 1,
		hour = 12, min = 0, sec = 0,
	})
	local today = os.date("%Y-%m-%d", now)
	local yesterday = os.date("%Y-%m-%d", yesterday_ts)
	-- 构建会话卡片。归档/恢复按钮与卡片主体是同级兄弟节点：
	-- 嵌进卡片里点击可能冒泡到卡片的 chat: action。
	local function chat_card(row)
		-- 索引来自外部脚本，字段可能缺失；逐个兜底，避免一行坏数据让整块侧栏崩掉。
		local raw_title = tostring(row.title or "未命名会话")
		local title = string.gsub(raw_title, "[%c]+", " ")
		local raw_cwd = tostring(row.cwd or "")
		-- 目录名统一走 project_name：与组头同一实现，还能剥掉尾部分隔符。
		local cwd = project_name(raw_cwd)
		local updated = tonumber(row.updated) or 0
		local row_id = tostring(row.id or "")
		local day = os.date("%Y-%m-%d", updated)
		local short_id = string.sub(row_id, 1, 8)
		local rel = relative_time(updated)
		local day_label = if day == today then "今天" elseif day == yesterday then "昨天" else os.date("%m-%d", updated)
		local meta_children = {
			ui.badge(rel, if day == today then "accent" else "muted"),
			ui.el("span", { text = day_label }),
			ui.el("span", { text = "·" }),
			ui.el("span", { text = cwd }),
			ui.el("span", { text = "·" }),
			ui.el("span", { text = short_id }),
		}
		-- 归档视图补一个项目名 badge，方便辨认会话属于哪个项目。
		if view_archived and raw_cwd ~= "" then
			table.insert(meta_children, ui.el("span", { class = "omp-history-archived-badge", text = project_name(raw_cwd) }))
		end
		local card = ui.el("button", {
			key = "chat_" .. row_id,
			class = "omp-history-card" .. (if grouped then " omp-history-card-indented" else ""),
			title = title .. "\n" .. raw_cwd .. "\n" .. row_id,
			actions = { click = "chat:" .. row_id },
		}, {
			ui.el("div", { class = "omp-history-title", text = title }),
			-- ui.node 不吃 class，必须用 ui.el div 承载 .omp-history-meta 的 flex 布局。
			ui.el("div", { class = "omp-history-meta" }, {
				ui.node("row", { gap = "xs" }, meta_children),
			}),
		})
		local del = ui.el("button", {
			key = "del_" .. row_id,
			class = "omp-history-card-action omp-history-card-delete",
			title = "彻底删除此会话文件",
			actions = { click = "del:" .. row_id },
		}, { ui.el("span", { class = "sf", text = "󰆴" }) })
		local action = if view_archived
			then ui.el("button", {
				key = "unarch_" .. row_id,
				class = "omp-history-card-action",
				title = "恢复到主列表",
				actions = { click = "unarchive:" .. row_id },
			}, { ui.el("span", { class = "sf", text = "󰁜" }) })
			else ui.el("button", {
				key = "arch_" .. row_id,
				class = "omp-history-card-action",
				title = "归档此会话",
				actions = { click = "archive:" .. row_id },
			}, { ui.el("span", { class = "sf", text = "󰆔" }) })
		return ui.node("row", { gap = "xs", class = "omp-history-card-row" }, { card, action, del })
	end
	if grouped and total_cards > 0 then
		for _, item in flatten_groups(build_groups()) do
			if item.kind == "group" then
				local group = item.group
				local collapsed = collapsed_projects[group.key] == true
				table.insert(cards, ui.el("button", {
					key = "group_" .. string.gsub(group.key, "[%c]+", "_"),
					class = "omp-history-group",
					title = group.key ~= "" and group.key or "工作目录未知",
					actions = { click = "group:" .. group.key },
				}, {
					ui.el("span", { class = "omp-history-chevron" .. (if collapsed then " omp-history-chevron-closed" else ""), text = "▼" }),
					ui.el("span", { class = "omp-history-group-name", text = group.name }),
					ui.el("span", { text = "·" }),
					ui.el("span", { class = "omp-history-group-count", text = tostring(#group.rows) }),
				}))
			else
				table.insert(cards, chat_card(item.row))
			end
		end
	else
		for _, row in filtered do
			table.insert(cards, chat_card(row))
		end
	end
	-- 防崩溃截断：画布节点超上限会让 canvas:set 永久失败。
	-- 不是分页：正常使用到不了 150 张卡，只是兜底提示去搜索。
	if #cards > MAX_VISIBLE_CARDS then
		local shown = 0
		for i, card in cards do
			if i > MAX_VISIBLE_CARDS then break end
			shown = shown + 1
		end
		local trimmed = {}
		for i = 1, shown do trimmed[i] = cards[i] end
		table.insert(trimmed, ui.el("div", {
			class = "omp-history-truncated",
			text = "还有 " .. (#cards - shown) .. " 个未显示，请用搜索缩小范围",
		}))
		cards = trimmed
	end
	local search_label = if query == "" then "搜索" else "搜索: " .. query
	local toolbar = {}
	-- 归档视图的入口/出口：主视图显示「归档 (n)」，归档视图显示「返回」。
	if view_archived then
		table.insert(toolbar, ui.button("返回", { icon = "arrow-left", title = "回到会话列表", size = "sm", actions = { click = "archive_view" } }))
	else
		local n = archived_count()
		table.insert(toolbar, ui.button(if n > 0 then "归档 " .. n else "归档", {
			icon = "box-archive", title = "查看已归档会话", size = "sm", actions = { click = "archive_view" },
		}))
	end
	table.insert(toolbar, ui.button(search_label, { icon = "search", title = "搜索标题、目录或会话 ID", size = "sm", actions = { click = "search" } }))
	if query ~= "" then
		table.insert(toolbar, ui.button("重置", { icon = "x", title = "清除搜索词并显示全部会话", size = "sm", actions = { click = "search_reset" } }))
	end
	table.insert(toolbar, ui.button("刷新", { icon = "repeat", title = "立即刷新会话索引", size = "sm", actions = { click = "refresh" } }))
	local main = ui.node("col", { gap = "sm" }, {
		ui.el("div", { class = "omp-history-toolbar" }, {
			ui.node("row", { gap = "sm", justify = "end" }, toolbar),
		}),
		ui.el("div", { class = "omp-history-list" }, cards),
	})
	local dock = ui.node("col", { gap = "none" }, {
		ui.el("div", { class = "omp-history-footer" }, {
			ui.el("div", { class = "omp-history-count", text = if view_archived
				then "已归档 " .. total_cards .. " 个"
				elseif total_cards == 0 then "0 个会话"
				else "共 " .. total_cards .. " 个" }),
		}),
	})
	return main, dock
end

-- 将当前列表同步到插件拥有的所有侧边栏。
-- 签名必须能吃出“可见内容”的变化：标题被 /rename 或索引刷新改写时，
-- id 集合往往不变，只有 title/path/updated 变了，否则刷新按钮会静默失效。
local function content_sig()
	local parts = {
		tostring(#filtered), query, tostring(error_text), tostring(loading),
		tostring(view_archived),
	}
	for _, row in filtered do
		parts[#parts + 1] = row.id
		parts[#parts + 1] = row.title
		parts[#parts + 1] = row.cwd
		parts[#parts + 1] = tostring(row.updated)
	end
	-- 分组模式额外吃出组序/组大小/折叠状态的变化，否则折叠点击和
	-- 索引刷新导致的组序变化不会重绘。
	if query == "" and not view_archived then
		for _, group in build_groups() do
			parts[#parts + 1] = "g:" .. group.key .. ":" .. #group.rows .. ":" .. tostring(group.rows[1].updated)
			parts[#parts + 1] = if collapsed_projects[group.key] then "c" else "o"
		end
	end
	-- 工具栏徽标数字变化也要重绘。
	parts[#parts + 1] = "a:" .. archived_count()
	return table.concat(parts, "\1")
end

local function redraw(cx)
	-- 签名对本轮所有 canvas 相同，提到循环外只算一次；命中重绘时视图也一样。
	local sig = content_sig()
	local main, dock
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			local tab = cx.session:tab_of(canvas.pane)
			-- tab_of 在面板刚创建、尚未注册时返回 nil；此时保留 open 时
			-- 记下的旧值，否则去重凭据被抹掉，下一个 tick 会再开一个。
			if tab then sidebar_tabs[canvas.pane] = tab end
			if last_sig[canvas.pane] ~= sig then
				if not main then main, dock = view() end
				-- 超节点上限时 canvas:set 会抛错；只在成功后才记账，
				-- 否则一次失败会让签名永久停留在“已发送”，后续内容变化不再重绘。
				local ok = pcall(cx.canvas.set, cx.canvas, canvas.pane, { view = main, dock = dock })
				if ok then last_sig[canvas.pane] = sig end
			end
		end
	end
end

-- 在后台读取索引，避免大目录扫描阻塞 Tern 窗口。
local function refresh(cx)
	if loading then return end
	loading = true
	-- 重读归档/折叠状态，吸收其他窗口通过 kv 提交的改动；立即重过滤，
	-- 即使索引加载失败也让当前视图反映最新的归档状态。
	sync_state_from_kv()
	filter_rows()
	-- 首选 python，spawn 失败（如 macOS/Linux 只有 python3）再试 python3；
	-- 已知可用解释器后记住它，避免每次 refresh 都先付一次失败的 spawn。
	local attempts = if python_cmd then { python_cmd } else { "python", "python3" }
	local function run_index()
		for i, cmd in attempts do
			local spawned, result_or_err = pcall(tern.process.run, { cmd, tern.plugin.dir .. "/sessions.py" }, { timeout_ms = 30000 }, function(result, next_cx)
				loading = false
				if not next_cx then return end
				if result.status ~= 0 then
					error_text = if result.stderr ~= "" then result.stderr else "索引程序运行失败"
				else
					python_cmd = cmd
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
			-- spawn 抛错：命令不存在。还有候选就试下一个。
			if spawned then return end
			if i == #attempts then
				loading = false
				-- spawn 失败抛的是字符串，直接附上它；python 与 python3 都找不到时
				-- 两处错误都能看到，而不是只显示最后一个命令名。
				error_text = "未找到 Python（" .. tostring(result_or_err) .. "），请安装 Python 并确认在 PATH 中"
				if cx then redraw(cx) end
			end
		end
	end
	run_index()
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
	-- 最后查自己 open 时记下的映射：宿主列表同步有延迟，刚开的面板
	-- 可能两边都还查不到，但记录已经在手，不能再开第二个。
	for _, sidebar_tab in sidebar_tabs do
		if sidebar_tab == tab then return end
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
	-- widgets 是一个整体数组，每次 window_start / 重载都读改写会和其他插件
	-- 或用户的并发修改抢写。写成功一次后就用 kv 记住，不再重复触碰。
	if tern.kv.get("widget_added") == true then return end
	local widgets = cx.settings:get("widgets") or {}
	for _, widget in widgets do
		if widget.id == "omp-history/toggle" then
			tern.kv.set("widget_added", true)
			return
		end
	end
	table.insert(widgets, { id = "omp-history/toggle" })
	local ok = pcall(cx.settings.set, cx.settings, "widgets", widgets)
	if ok then tern.kv.set("widget_added", true) end
end

-- 删除会话前经 cx:pick 确认；确认后彻底删除会话目录并刷新索引。
-- pick resolves 传入的原表（可带自定义字段），nil = 用户取消或被别的弹窗顶掉。
local function confirm_delete(cx, row)
	local row_id = tostring(row.id or "")
	local title = string.gsub(tostring(row.title or "未命名会话"), "[%c]+", " ")
	local path = tostring(row.path or "")
	if path == "" then
		cx:toast("error", "无法删除会话", "索引里没有该会话的文件路径")
		return
	end
	-- 会话目录 = jsonl 所在目录；删除目标是整个目录（README 同此口径）。
	-- 目录里是否有别的文件决定了删整目录还是只删 jsonl；探测放在确认之后，
	-- 避免弹窗期间目录变化导致用陈旧判断删错目标（TOCTOU）。
	local dir = string.match(path, "^(.*)[/\\][^/\\]+$") or path
	cx:pick({
		placeholder = "删除会话：" .. title,
		icon = "trash",
		action = "删除",
		items = {
			{ label = "彻底删除", detail = title, icon = "trash", act = "confirm", path = path, dir = dir, id = row_id },
			{ label = "取消", icon = "x", act = "cancel" },
		},
	}):next(function(item, err, next_cx)
		if not next_cx then return end
		if err then next_cx:toast("error", "删除确认失败", err) return end
		if not item or item.act ~= "confirm" then
			next_cx:toast("info", "已取消删除", title)
			return
		end
		-- 直接用 Tern 提供的同步文件 API 删除：跨平台，无 shell，
		-- 路径里的空格与 & | ^ 等字符不会被 shell 误解析，也没有注入面。
		-- 旧实现走 cmd.exe /c del 或 rm，路径含空格会失败且存在命令注入风险。
		-- 确认时重新探测目录：独占目录删整目录（连带 omp 附属文件），
		-- 目录里有别的文件时只删 jsonl。
		local shared_dir = false
		do
			local ok, entries = pcall(tern.fs.list, dir)
			if ok and type(entries) == "table" then
				for _, name in entries do
					if dir .. "/" .. name ~= path and dir .. "\\" .. name ~= path then
						shared_dir = true
						break
					end
				end
			end
		end
		local target = if shared_dir then path else dir
		local removed, remove_err = pcall(tern.fs.remove, target)
		if not removed then
			next_cx:toast("error", "删除会话失败", tostring(remove_err))
			return
		end
		-- 会话没了，归档记录里的残留键一并清掉，避免 kv 无限膨胀
		-- （折叠键按 cwd 记录，与单个会话无关，不需要清理）。
		archived_sessions[item.id] = nil
		save_archived()
		next_cx:toast("success", "会话已删除", title)
		refresh(next_cx)
	end)
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
	if not target then
		cx:toast("error", "无法恢复会话", row.title)
		return
	end
	local launch = { command = "omp --resume " .. shell_quote(row.path, shell_for_pane(cx, target)) }
	if row.cwd ~= "" then launch.cwd = row.cwd end
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
	local key = if not id then string.match(ev.act, "^group:(.+)$") else nil
	local arch_id = if not id and not key then string.match(ev.act, "^archive:(.+)$") else nil
	local unarch_id = if not id and not key and not arch_id then string.match(ev.act, "^unarchive:(.+)$") else nil
	if id then
		for _, row in rows do
			if row.id == id then
				open_chat(cx, row, ev.pane)
				break
			end
		end
	elseif key then
		-- 组键是完整 cwd 路径，action 字符串里不会出现换行，直接拼回去安全。
		if collapsed_projects[key] then
			collapsed_projects[key] = nil
		else
			collapsed_projects[key] = true
		end
		save_collapsed()
		redraw(cx)
	elseif arch_id then
		archived_sessions[arch_id] = true
		save_archived()
		-- 归档视图里如果正搜着被归档的会话，过滤集要跟着变。
		filter_rows()
		redraw(cx)
	elseif unarch_id then
		archived_sessions[unarch_id] = nil
		save_archived()
		filter_rows()
		redraw(cx)
	elseif string.match(ev.act, "^del:(.+)$") then
		local del_id = string.match(ev.act, "^del:(.+)$")
		for _, row in rows do
			if row.id == del_id then
				confirm_delete(cx, row)
				break
			end
		end
	elseif ev.act == "archive_view" then
		view_archived = not view_archived
		query = ""
		filter_rows()
		redraw(cx)
	elseif ev.act == "search" then
		cx:prompt({ value = query, placeholder = "搜索标题、目录或会话 ID", action = "search" }):next(function(value, err, next_cx)
			if not next_cx then return end
			if err then next_cx:toast("error", "搜索失败", err) return end
			if value ~= nil then
				-- 首尾空白会让精确匹配搜不到任何结果，先剥掉。
				query = string.match(value, "^%s*(.-)%s*$") or value
				filter_rows()
				redraw(next_cx)
			end
		end)
	elseif ev.act == "search_reset" then
		query = ""
		filter_rows()
		redraw(cx)
	elseif ev.act == "refresh" then
		refresh(cx)
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
	if not cx then return end
	-- 去重：同一 tab 只允许一个 OMP History canvas，多余的关掉。
	-- 一次扫 pane 得到 tab 与每 tab 的 pane 计数，避免在 canvas 循环里再扫一遍。
	local seen_tab = {}
	local pane_tab = {}
	local tab_count = {}
	local owned = {}
	local closed_any = false
	for _, info in ipairs(cx.session:panes()) do
		pane_tab[info.pane] = info.tab
		if info.tab then tab_count[info.tab] = (tab_count[info.tab] or 0) + 1 end
		if info.program == "tern.canvas" and info.title == TITLE then owned[info.pane] = true end
	end
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			owned[canvas.pane] = true
			local tab = pane_tab[canvas.pane] or cx.session:tab_of(canvas.pane)
			if tab then sidebar_tabs[canvas.pane] = tab end
			if tab then
				if seen_tab[tab] then
					sidebar_tabs[canvas.pane] = nil
					last_sig[canvas.pane] = nil
					cx.layout:close(canvas.pane)
					closed_any = true
				else
					seen_tab[tab] = canvas.pane
				end
			end
			if tab and tab_count[tab] == 1 then
				sidebar_tabs[canvas.pane] = nil
				last_sig[canvas.pane] = nil
				cx.layout:close(canvas.pane)
				closed_any = true
			end
		end
	end
	-- 校验记录：面板连续 5 秒不在宿主列表里才视为已死（比如 open
	-- 失败留下的幽灵记录），否则只是同步延迟，先留着供去重使用。
	local now_ms = tern.now()
	for pane in sidebar_tabs do
		if owned[pane] then
			missing_since[pane] = nil
		else
			local since = missing_since[pane]
			if not since then
				missing_since[pane] = now_ms
			elseif now_ms - since > 5000 then
				sidebar_tabs[pane] = nil
				missing_since[pane] = nil
			end
		end
	end
	-- 刚关掉的这一 tick 别立刻重开，否则形成每秒开关环。
	if not closed_any then ensure_sidebar(cx) end
end

-- 关闭整个标签时不改变其他标签的历史侧边栏显示状态。
tern.on("tab_closed", function(ev)
	for pane, tab in sidebar_tabs do
		if tab == ev.tab then sidebar_tabs[pane] = nil end
	end
end)

tern.on("pane_closed", function(ev, cx)
	local was_sidebar = sidebar_tabs[ev.pane] ~= nil
	sidebar_tabs[ev.pane] = nil
	last_sig[ev.pane] = nil
	missing_since[ev.pane] = nil
	for tab, pane in chat_panes do
		if pane == ev.pane then chat_panes[tab] = nil end
	end
	if was_sidebar and tern.kv.get("visible") == true then
		hide_sidebars(cx, ev.pane)
	end
end)

-- 定期刷新历史，手动刷新和搜索不必等待定时器。
-- 用户正在搜索或停在归档视图时跳过：列表按 mtime 排序，后台写入会让
-- 卡片跳位，打断浏览。
local function view_is_stable()
	if query ~= "" or view_archived then return false end
	return true
end

local function refresh_tick(cx)
	if cx and view_is_stable() then refresh(cx) end
end

tern.on("window_start", function(cx)
	initialize_visibility(cx)
	ensure_toolbar_widget(cx)
	load_collapsed()
	load_archived()
	ensure_sidebar(cx)
	refresh(cx)
end)
-- 插件重载不会重新触发 window_start，需要主动恢复索引。
every("boot", 100, function(cx)
	if cx then
		initialize_visibility(cx)
		ensure_toolbar_widget(cx)
		load_collapsed()
		load_archived()
		refresh(cx)
		-- 初始化完成即停：这里只是补跑 reload 后缺失的 window_start，
		-- 不是轮询；继续挂着会让 refresh 每 100ms 背靠背拉起索引脚本。
		local slot = timer_slots.boot
		if slot and slot.handle then pcall(slot.handle.cancel, slot.handle) end
		timer_slots.boot = nil
	end
end)
every("tick", 1000, tick)
every("refresh", 30000, refresh_tick)

-- 重载或关闭插件时取消所有 timer，并释放可能仍在跑的子进程。
tern.on("unload", function()
	unloading = true
	for _, slot in timer_slots do
		if slot.handle then pcall(slot.handle.cancel, slot.handle) end
	end
	timer_slots = {}
	loading = false
end)
