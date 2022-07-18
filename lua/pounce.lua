local matcher = require "pounce.matcher"
local log = require "pounce.log"
local vim = vim

local CURRENT_LINE_BONUS = 1
local CURRENT_WINDOW_BONUS = 0.5

local M = {}

local config = {
  accept_keys = "JFKDLSAHGNUVRBYTMICEOXWPQZ",
  accept_best_key = "<enter>",
  multi_window = true,
  debug = false,
}

local last_input = ""

local function getconfig(key, opts)
  if opts and opts[key] ~= nil then
    return opts[key]
  else
    return config[key]
  end
end

local function get_windows(opts)
  local wins
  if not string.find(vim.api.nvim_get_mode().mode, "o") and getconfig("multi_window", opts) then
    wins = vim.api.nvim_tabpage_list_wins(0)
  else
    wins = { vim.api.nvim_get_current_win() }
  end
  local filtered_wins = {}
  for _, win in ipairs(wins) do
    -- Ignore windows we can't switch to (like Telescope).
    if vim.api.nvim_win_get_config(win).focusable then
      table.insert(filtered_wins, win)
    end
  end
  return filtered_wins
end

function M.setup(opts)
  for k, v in pairs(opts) do
    config[k] = v
  end
end

function M.pounce(opts)
  local active_win = vim.api.nvim_get_current_win()
  local cursor_pos = vim.api.nvim_win_get_cursor(active_win)
  local windows = get_windows(opts)
  local ns = vim.api.nvim_create_namespace ""
  local input = opts and opts.do_repeat and last_input or ""
  local hl_prio = 65533
  local leader_press = false

  while true do
    local start_clock = os.clock()

    local accept_key_map = {}

    for _, win in ipairs(windows) do
      vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), ns, 0, -1)
    end

    -- Fake cursor highlight
    local cur_line = vim.api.nvim_get_current_line()
    local cur_col = cursor_pos[2]
    local cur_row = cursor_pos[1] - 1
    -- Check to see if cursor is at end of line or on empty line
    if #cur_line == cur_col then
      vim.api.nvim_buf_set_extmark(0, ns, cur_row, cur_col, {
        virt_text = { { "█", "Normal" } },
        virt_text_pos = "overlay",
        priority = hl_prio,
      })
    else
      vim.api.nvim_buf_set_extmark(0, ns, cur_row, cur_col, {
        end_col = cur_col + 1,
        hl_group = "TermCursor",
        priority = hl_prio,
      })
    end

    for _, win in ipairs(windows) do
      local buf = vim.api.nvim_win_get_buf(win)
      local win_info = vim.fn.getwininfo(win)[1]
      vim.api.nvim_buf_set_extmark(buf, ns, win_info.topline - 1, 0, {
        end_line = win_info.botline,
        hl_group = "PounceUnmatched",
        hl_eol = true,
        priority = hl_prio - 1,
      })
    end

    if input ~= "" then
      local hits = {}
      local current_win = vim.api.nvim_get_current_win()

      -- Find and score all matches in visible buffer regions.
      for _, win in ipairs(windows) do
        local buf = vim.api.nvim_win_get_buf(win)
        local win_info = vim.fn.getwininfo(win)[1]
        local cursor_line, cursor_col = unpack(vim.api.nvim_win_get_cursor(win))
        for line = win_info.topline, win_info.botline do
          local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
          local matches = matcher.match(input, text)
          for _, m in ipairs(matches) do
            local score = m.score
            if win == current_win then
              score = score + CURRENT_WINDOW_BONUS
              if line == cursor_line then
                score = score + CURRENT_LINE_BONUS
              end
            end
            if
              buf == vim.api.nvim_win_get_buf(active_win)
              and cursor_line == line
              and cursor_col + 1 == m.indices[1]
            then
              -- Ignore match at current cursor position.
              score = 0
            end
            table.insert(hits, { window = win, line = line, indices = m.indices, score = score })
            if getconfig("debug", opts) then
              vim.api.nvim_buf_set_extmark(buf, ns, line - 1, -1, { virt_text = { { tostring(score), "IncSearch" } } })
            end
          end
        end
      end

      -- Discard relatively low-scoring matches.
      hits = matcher.filter(hits)

      table.sort(hits, function(a, b)
        return a.score > b.score
      end)

      -- Highlight and assign accept keys to matches.
      local seen = {}
      for idx, hit in ipairs(hits) do
        local buf = vim.api.nvim_win_get_buf(hit.window)
        -- Avoid duplication when the same buffer is visible in multiple windows.
        local seen_key = string.format("%d.%d.%d", buf, hit.line, hit.indices[1])
        if seen[seen_key] == nil then
          seen[seen_key] = true
          vim.api.nvim_buf_set_extmark(buf, ns, hit.line - 1, hit.indices[1] - 1, {
            end_col = hit.indices[#hit.indices] - 1,
            hl_group = "PounceGap",
            priority = hl_prio,
          })
          for _, index in ipairs(hit.indices) do
            vim.api.nvim_buf_set_extmark(buf, ns, hit.line - 1, index - 1, {
              end_col = index,
              hl_group = "PounceMatch",
              priority = hl_prio,
            })
          end

          local accept_keys = getconfig("accept_keys", opts)
          if idx <= accept_keys:len() then
            local accept_key = accept_keys:sub(idx, idx)
            accept_key_map[accept_key] = { window = hit.window, position = { hit.line, hit.indices[1] - 1 } }
            local hl = "PounceAccept"
            if idx == 1 and getconfig("accept_best_key", opts) then
              hl = "PounceAcceptBest"
              local key = vim.api.nvim_replace_termcodes(getconfig("accept_best_key", opts), true, true, true)
              accept_key_map[key] = accept_key_map[accept_key]
            end
            vim.api.nvim_buf_set_extmark(
              buf,
              ns,
              hit.line - 1,
              hit.indices[1] - 1,
              { virt_text = { { accept_key, hl } }, virt_text_pos = "overlay" }
            )
          end
        end
      end
    end

    local elapsed = os.clock() - start_clock
    log.debug("Matching took " .. elapsed * 1000 .. "ms")

    vim.api.nvim_echo({ { "pounce> ", "Keyword" }, { input } }, false, {})
    vim.cmd "redraw"

    local ok, nr = pcall(vim.fn.getchar)
    if not ok then
      break
    end

    if nr == 32 then
      if not leader_press then
        leader_press = true
        nr = 0
      else
        -- nr = " "
      end
    elseif leader_press then
      leader_press = false
      if nr >= 97 and nr <= 122 then
        nr = nr - 32
      end
    end

    if nr == 0 then
    elseif nr == 27 then -- escape
      break
    elseif nr == "\x80kb" then -- backspace
      input = input:sub(1, -2)
    else
      local ch = vim.fn.nr2char(nr)
      local accepted = accept_key_map[ch]
      if accepted ~= nil then
        -- accept match
        vim.cmd "normal! m'"
        vim.api.nvim_win_set_cursor(accepted.window, accepted.position)
        vim.api.nvim_set_current_win(accepted.window)
        break
      elseif type(nr) == "number" and (nr < 32 or nr == 127) then
        -- ignore
      else
        input = input .. ch
      end
    end
    last_input = input
  end

  for _, win in ipairs(windows) do
    vim.api.nvim_buf_clear_namespace(vim.api.nvim_win_get_buf(win), ns, 0, -1)
  end
  vim.api.nvim_echo({}, false, {})
end

return M
