-- Run in a fresh Neovim process inside each terminal; see docs/performance.md.
-- Timings measure Neovim's redraw cadence, not presented FPS or input latency.
assert(vim.v.vim_did_enter == 0, 'Start a fresh Neovim with -c "luafile Scripts/perf-nvim-scroll.lua"')
local report = assert(vim.env.CHERRY_NVIM_SCROLL_REPORT, 'Set CHERRY_NVIM_SCROLL_REPORT to a JSON output path')
local frames = tonumber(vim.env.CHERRY_NVIM_SCROLL_FRAMES or '2400')
local interval = tonumber(vim.env.CHERRY_NVIM_SCROLL_INTERVAL_MS or '8')
assert(frames and frames > 0 and frames % 1 == 0, 'Frame count must be a positive integer')
assert(interval and interval >= 1 and interval % 1 == 0, 'Interval must be a positive integer in milliseconds')

vim.o.swapfile = false
vim.o.mouse = 'a'
vim.o.number = true
vim.o.laststatus = 2
local lines = {}
for i = 1, frames * 3 + 200 do
    lines[i] = string.format('local line_%05d = { name = "scroll benchmark", value = %d, enabled = true }', i, i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.bo.filetype = 'lua'
vim.cmd('syntax on')

local timer = assert(vim.uv.new_timer())
local frame, samples = 0, {}
vim.defer_fn(function()
    local start = vim.uv.hrtime()
    timer:start(0, interval, vim.schedule_wrap(function()
        -- A timer callback may already be queued when the final frame stops it.
        if frame >= frames then return end
        frame = frame + 1
        vim.cmd('normal! 3' .. string.char(5)) -- Ctrl-E: scroll down three lines.
        vim.cmd('redraw')
        samples[frame] = (vim.uv.hrtime() - start) / 1e6
        if frame == frames then
            timer:stop()
            timer:close()
            local gaps = {}
            for i = 2, #samples do gaps[#gaps + 1] = samples[i] - samples[i - 1] end
            table.sort(gaps)
            vim.fn.writefile({ vim.json.encode({
                frames = frames,
                interval_ms = interval,
                elapsed_ms = samples[frame],
                p95_redraw_gap_ms = gaps[math.max(1, math.ceil(#gaps * 0.95))] or 0,
                max_redraw_gap_ms = gaps[#gaps] or 0,
                columns = vim.o.columns,
                rows = vim.o.lines,
                neovim_version = vim.version(),
                redraw_completed_ms = samples,
            }) }, report)
            vim.cmd('qa!')
        end
    end))
end, 3000)
