#!/usr/local/bin/lua
-- Simple getopt - Fidelis Assis

function getopt(args, opt_table)
  local skip = false
  local options_found = {}
  local key
  local optind

  for i, o in ipairs(args) do
    optind = i
    if not skip then
      key, value = string.match(o, "^-%-?([^=]*)=?(.*)")

      if key then
        optind = i + 1
        if key == "" then
          break -- end of options found
        end

        if (opt_table[key] == 1) then
          if value == "" then
            options_found[key] = args[i+1]
            skip = true
          else
            options_found[key] = value
          end
        elseif (opt_table[key] == 0) then
          options_found[key] = 1
        elseif (opt_table[key] == 2) then
          if value == "" then
            options_found[key] = 1
          else
            options_found[key] = value
          end
        else
          optind = nil
          options_found = "Invalid option: " .. o
          break
        end
      else
        break -- only parameters left
      end
    else
      skip = false
    end
  end

  return optind, options_found
end

