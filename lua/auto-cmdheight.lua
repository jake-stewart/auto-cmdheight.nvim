--- @type any
local uv = vim.uv or vim.loop
table.unpack = table.unpack or unpack

local function restore_winviews(winviews)
    for win_id, winview in pairs(winviews) do
        pcall(vim.api.nvim_win_call, win_id, function()
            pcall(vim.fn.winrestview, winview)
        end)
    end
end

local function save_winviews()
    local win_ids = vim.api.nvim_tabpage_list_wins(0)
    local winviews = {}
    for _, win_id in ipairs(win_ids) do
        winviews[win_id] = vim.api.nvim_win_call(
            win_id, vim.fn.winsaveview)
    end
    return winviews
end

local CmdheightManager = {
    opts = nil, --- @type AutoCmdheightOpts
    settings = nil,
    nsid = nil,
    active = false,
    in_cmd_line = false,
    key_pressed = false,
    printed = false,
    scheduled_deactivate = false,
    nvim_echo = vim.api.nvim_echo,
    cmd_echo = vim.cmd.echo,
    print = print,
}

function CmdheightManager:override_settings()
    if not self.settings then
        self.settings = {
            ruler = vim.o.ruler,
            showcmd = vim.o.showcmd
        }
        vim.o.ruler = false
        vim.o.showcmd = false
    end
end

function CmdheightManager:restore_settings()
    if self.settings then
        vim.o.ruler = self.settings.ruler
        vim.o.showcmd = self.settings.showcmd
        self.settings = nil
    end
end

function CmdheightManager:schedule_deactivate()
    if not self.scheduled_deactivate then
        self.scheduled_deactivate = true
        vim.schedule(function()
            if self.scheduled_deactivate then
                self:deactivate()
            end
        end)
    end
end

function CmdheightManager:subscribe_key()
    vim.on_key(function()
        self:unsubscribe_key()
        self:schedule_deactivate()
    end, self.nsid)
end

function CmdheightManager:subscribe_timer()
    self.timer = vim.defer_fn(function()
        if self.opts.remove_on_key then
            self:subscribe_key()
        else
            self:deactivate()
        end
    end, math.floor(self.opts.duration * 1000))
end

function CmdheightManager:unsubscribe_key()
    vim.on_key(nil, self.nsid)
end

function CmdheightManager:unsubscribe_timer()
    if self.timer then
        uv.timer_stop(self.timer)
        self.timer = nil
    end
end

function CmdheightManager:deactivate(winviews)
    if self.active then
        if not winviews then
            winviews = save_winviews()
        end
        self.active = false

        local tab_ids = vim.api.nvim_list_tabpages()
        for _, tab_id in ipairs(tab_ids) do
            local win_id = vim.api.nvim_tabpage_get_win(tab_id)
            vim.api.nvim_win_call(win_id, function()
                vim.o.cmdheight = self.cmdheight
            end)
        end

        if self.opts.clear_always then
            self.nvim_echo({}, false, {})
        end
        self:restore_settings()
        self:unsubscribe_key()
        self:unsubscribe_timer()
        vim.o.cmdheight = self.cmdheight
        restore_winviews(winviews)
        vim.cmd.redraw()
    end
end

function CmdheightManager:activate(str)
    if self.in_cmd_line or vim.in_fast_event() then
        return
    end
    if self.printed then
        self:schedule_deactivate()
        return
    end
    self.printed = true

    local winviews = save_winviews()

    self:restore_settings()

    if not self.active then
        self.cmdheight = vim.o.cmdheight
    end

    local echospace = vim.v.echospace
    local columns = vim.o.columns

    str = str:gsub("\t", "12345678")
    local lines = vim.split(str, "\n", {
        plain = true,
        trimempty = false,
    })
    local num_lines = 0
    for _, line in ipairs(lines) do
        local len = vim.fn.strwidth(line)
        num_lines = num_lines + 1 + math.floor(
            math.max(0, len - 1) / columns)
        if len >= columns and len % columns == 0 then
            num_lines = num_lines + 1
        end
    end

    local remainder = vim.fn.strwidth(lines[#lines]) % columns
    local override = remainder > echospace and num_lines >= self.cmdheight

    if (num_lines <= self.cmdheight and not override
        or num_lines > self.opts.max_lines)
        and not self.opts.clear_always
    then
        self:deactivate(winviews)
        return
    end

    self.active = true
    self.scheduled_deactivate = false

    self:unsubscribe_key()
    self:unsubscribe_timer()
    self:subscribe_timer()

    if override then
        self:override_settings()
    end
    vim.o.cmdheight = math.max(num_lines, self.cmdheight)
    restore_winviews(winviews)
    vim.cmd.redraw()
end

--- @param opts AutoCmdheightOpts
function CmdheightManager:setup(opts)
    self.opts = opts

    self.nsid = vim.api.nvim_create_namespace("auto-cmdheight")
    vim.api.nvim_create_augroup("auto-cmdheight", { clear = true })

    vim.api.nvim_create_autocmd("CmdlineEnter", {
        pattern = "*",
        group = "auto-cmdheight",
        callback = function()
            self.in_cmd_line = true
            self:deactivate()
        end
    })
    vim.api.nvim_create_autocmd("CmdlineLeave", {
        pattern = "*",
        group = "auto-cmdheight",
        callback = function()
            self.in_cmd_line = false
            self:deactivate()
        end
    })
    vim.api.nvim_create_autocmd("VimResized", {
        pattern = "*",
        group = "auto-cmdheight",
        callback = function()
            self:deactivate()
        end
    })
    vim.api.nvim_create_autocmd("SafeState", {
        pattern = "*",
        group = "auto-cmdheight",
        callback = function()
            self.printed = false
            if not self.scheduled_deactivate
                and vim.fn.state("s") == "s"
            then
                self:schedule_deactivate()
            end
        end
    })

    function _G.print(...)
        local n = select("#", ...)
        local args = { ... }
        if n > 0 then
            for i = 1, n do
                args[i] = tostring(args[i])
            end
            if vim.endswith(args[n], "\n") then
                args[n] = string.sub(
                    args[n], 1, #args[n] - 1)
            end
        end
        local message = table.concat(args, " ")
        self:activate(message)
        self.print(message)
    end

    --- @diagnostic disable-next-line
    function vim.api.nvim_echo(chunks, _history, _opts)
        local buffer = {}
        local error = false
        if type(chunks) ~= "table" then
            error = true
        else
            for _, chunk in ipairs(chunks) do
                if type(chunk) ~= "table" or type(chunk[1]) ~= "string" then
                    error = true
                    break
                end
                table.insert(buffer, chunk[1])
            end
        end
        if not error then
            if #chunks > 0 and #buffer > 0 then
                if vim.endswith(buffer[#buffer], "\n") then
                    buffer[#buffer] = string.sub(buffer[#buffer], 0, #buffer[#buffer] - 1)
                    local chunk = chunks[#chunks]
                    chunk[1] = string.sub(chunk[1], 0, #chunk[1] - 1)
                end
            end
            self:activate(table.concat(buffer, ""))
        end
        self.nvim_echo(chunks, _history, _opts)
    end
end

--- @class AutoCmdheightOpts
--- @field max_lines? number
--- @field duration? number
--- @field remove_on_key? boolean
--- @field clear_always? boolean

local M = {}

--- @param opts? AutoCmdheightOpts
function M.setup(opts)
    opts = vim.tbl_extend("keep", opts or {}, {
        max_lines = 5,
        duration = 2,
        remove_on_key = true,
        clear_always = false,
    })
    opts.duration = math.max(opts.duration, 0.1)
    CmdheightManager:setup(opts)
end

return M
