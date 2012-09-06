#! /usr/local/bin/lua
-- Script for spam filtering
-- Copyright (C) 2005, 2006, 2007 Fidelis Assis <fidelis@pobox.com>
                                                 
-- spamfilter version
gSf_version = "2.0.3"

require "osbf"   -- load osbf library

-- clear classification and learning flags
osbf.cfg_classify_flags    = 0
osbf.cfg_learn_flags       = 0

-- NOT USED!
-- minimum number of trainings to start tagging the subject line
-- while the min trainings is not reached, sfid tag is defined as "u"
gMin_trainings = 10

-- number of trainings for each databases
gTrainings = {}

-- max text len for classification an learning
gMax_text_len = 500000

-- environment variables
gUser_osbf_dir = ""
gUser_cache_dir = ""

-- simple getopt to get command line options
function getopt(args, opt_table)
  local skip = false
  local options_found = {}
  local key
  local optind

  for i, o in ipairs(args) do
    if not skip then
      key, value = string.match(o, "^-%-?([^=]*)=?(.*)")

      if key then
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
        optind = i
        break -- only parameters left
      end
    else
      skip = false
    end
    optind = i + 1
  end

  return optind, options_found
end

-- check if a file exists
function file_exists(file)
  local f = io.open(file, "r")
  if f then
    f:close()
    return true
  else
    return nil, "File not found"
  end
end

-- check if file exists before "doing" it
function my_dofile(file)
  local f, err_msg = loadfile(file)
  if (f) then
    f()
    return true
  else
    return false
  end
end

-- log string to filename in the log dir
function spamfilter_log(str, filename, prepend_time)
  local log = io.open(filename, "a+")
  if log then
    if prepend_time then log:write(os.date("%c - ")) end
    if type(str) == "string" then
      log:write(str)
    elseif type(str) == "table" then
	for i, e in pairs(str) do
          log:write(i, e, "\n")
        end
    end
    if prepend_time then log:write("\n") end
    log:close()
    return true
  else
    return nil
  end
end

-- append slash if missing
function append_slash(path)
  if path then
    if string.sub(path, -1) ~= "/" then
      return path .. "/"
    else
      return path
    end
  else
    return nil
  end
end

-- get tags according to pR value
function get_tags(pR)
  local subj_tag, sfid_tag

  if (pR == nil) then
     subj_tag = ""
     sfid_tag = "E" -- error
  else
     if pR < (osbf.cfg_min_pR_success - osbf.cfg_threshold) then
       subj_tag = osbf.cfg_tag_spam
       sfid_tag = "S"
     elseif pR > (osbf.cfg_min_pR_success + osbf.cfg_threshold) then
       subj_tag = osbf.cfg_tag_ham
       sfid_tag = "H"
     elseif pR >= osbf.cfg_min_pR_success then
       subj_tag = osbf.cfg_tag_unsure_ham
       sfid_tag = "+"
     else
       subj_tag = osbf.cfg_tag_unsure_spam
       sfid_tag = "-"
     end
  end
  return subj_tag, sfid_tag
end

function tag_subject(header, subj_tag)
  
  if (osbf.cfg_tag_subject and subj_tag ~= "") then
    local i, j = string.find(header, "\n[Ss][Uu][Bb][Jj][Ee][Cc][Tt][ \t]-:")

    if (i == nil) then
      -- if there's no subject, add one
      header = header .. "Subject: " .. subj_tag .. " (no subject)\n"
    else
      -- tag all subject lines found
      header = string.gsub(header,
                           "(\n[Ss][Uu][Bb][Jj][Ee][Cc][Tt][ \t]-:)",
                           "%1 " .. subj_tag)
    end
  end

  return header
end

function insert_sfid(header, sfid, where)
  local i, j

  if not where then where = "references" end

  -- remove old, dangling sfids
  header = string.gsub(header,
	"[%s]-[<%(]sfid%-.%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%S-@" ..
	osbf.cfg_rightid .. "[>%)]", "")

  if where == "references" or where == "both" then
    i, j = string.find(header .. "\n",
		"\n[Rr][Ee][Ff][Ee][Rr][Ee][Nn][Cc][Ee][Ss][ \t]-:.-\n[^ \t]")
    if (i) then
      -- yes, append the SFID as a reference  
      header = string.sub(header, 1, j-2) ..
			" \n\t<" .. sfid .. ">" .. string.sub(header, j-1)
    else
      -- no references found; create one and add the sfid
      header = header .. "References: <" .. sfid .. ">\n"
    end
  end
  if where == "message-id" or where == "both" then
    i, j = string.find(header .. "\n",
		"\n[Mm][Ee][Ss][Ss][Aa][Gg][Ee]%-[Ii][Dd]%s-:.-\n[^ \t]")
    if (i) then
      -- yes, append the SFID as a comment to message-id
      header = string.sub(header, 1, j-2) ..
			" \n\t(" .. sfid .. ")" .. string.sub(header, j-1)
    else
      -- no message-id found; create one and add the sfid
      header = header .. "Message-ID: <" .. sfid .. "> (" .. sfid .. ")\n"
    end
  end

  return header
end

--------------- start of program  ------------------

-- handle command line options

gOptind, gOptions = getopt(arg,
	{ udir = 1, gdir = 1, learn = 1, unlearn = 1, classify = 0,
	  score = 0, cfgdir = 1, dbdir = 1, listsdir = 1, source = 1,
	  output = 1, help = 0})

gMyPath = string.match(arg[0], "^(.*/)") or "./"

if type(gOptions) ~= "table" then
  if type(gOptions) == "string" then
    io.stderr:write("Error:", gOptions, "\n")
  else
    io.stderr:write("Error while reading command line options\n")
  end
  return 1
end

if gOptions["help"] then
  io.write([[
Usage: spamfilter.lua [COMMAND] [OPTION]... [FILE]

Classify, learn or unlearn standard input, or FILE if one is given,
depending on COMMAND.

- Commands

  --classify
        classify  a  message   read  from  stdin  and  print  just  the
        X-OSBF-Lua-Score header line that would be added to the message
        header.

  --learn=spam|nonspam
        learn a message from stdin as spam or not spam, respectively.
        The source of the message can be changed with the option
        --source.

  --score
        classify a message read from stdin and print just the score.

  --unlearn=spam|nonspam
        undo (approx.) a  previous  learn  done by mistake. The message
        is read from  stdin. The source of the  message can  be changed
        with the option --source.

- Options

  --udir=<user_dir>
        set  the  user  directory,  where  its  osbf-lua  configuration,
        databases,  lists and log files  are located.  The  location  of
        these files can also be set individually, see the options below.
	Default: current dir.


  --gdir=<global_dir>
        set the  global directory where spamfilter.lua  is installed and
        where    it    looks    for   its    companion    files,    like
        spamfilter_commands.lua, spamfilter.help, etc.
	Default: current dir.


  --cfdir=<config_dir>
        specify  a location  for the  configuration file  different than
        that specified with --udir.


  --dbdir=<database_dir>
        specify a  location for the  database files different  than that
        specified with --udir.


  --listdir=<list_dir>
        specify  a  location  for  the  list  files,  whitelist.lua  and
        blacklist.lua, different than that specified with --udir.

  --source=stdin|sfid|body
        set the source of the message to be used in a trainining, when
        one of the commands --learn or --unlearn is used.
        - stdin: the message is exactly what is read from stdin
        - sfid:  the message is recovered from the cache using the sfid
                 in the headers of the message read from stdin.
        - body:  the message to be trained with is the body of the
                 message read from stdin.

        The default value is "stdin", that is, when this option is not
        specified.

  --output=report|message
        determine what is written to stdout after training a message, the
        default report or the original message classified as spam or ham,
        according to the training command.

If no command-line command is specified, spamfilter.lua looks for one of
the send-to-yourself  commands in  the subject line  and executes  it if
found. If  no subject line command  is found, it searches  the first 100
chars of the message body for a command. If no command is found, it then
performs a normal classification, adds a X-OSBF-Lua-Score to the message
header, does  other actions specified  in the config file,  like tagging
the subject line, and prints the message to the standard output.

]])
  return 0
end


gUser_osbf_dir	 = append_slash(gOptions["udir"])     or "./"
gGlobal_osbf_dir = append_slash(gOptions["gdir"])     or gMyPath
gConfig_dir	 = append_slash(gOptions["cfgdir"])   or gUser_osbf_dir
gDatabase_dir	 = append_slash(gOptions["dbdir"])    or gUser_osbf_dir
gLists_dir	 = append_slash(gOptions["listsdir"]) or gUser_osbf_dir

if gOptions["output"] == "message" then
  osbf.cfg_output = "message"
elseif gOptions["output"] == "report" then
  osbf.cfg_output = "report"
end

-- set user log dir and filename
gUser_log_dir = gUser_osbf_dir .. "log/"
gError_log_file = "error_log"

-- set user cache dir and filename
gUser_cache_dir = gUser_osbf_dir .. "cache/"

local command_line = false
if gOptions["learn"] or gOptions["unlearn"] then
  command_line = true
end

-- read entire message into var "gText"
if arg[gOptind] then -- check if a filename is given in the command line
  local h = io.open(arg[gOptind], "r")
  if h then 
    gText = h:read("*all")
    h:close()
  else
    io.write("Error: File not found: " .. arg[gOptind], "\n")
    return 1
  end
else
  gText = io.read("*all")
end

--[[
-- find out the EOL sequence
gEOL = "\n"
local num_CR, num_LF, num_CR
if gText then
  _, num_LF   = string.gsub(gText, "\n", {})
  _, num_CRLF = string.gsub(gText, "\r\n", {})
  if num_LF > 0 then
    if num_LF == num_CRLF then
      gEOL = "\r\n"
    else
      gEOL = "\n"
    end
  else
    _, num_CR   = string.gsub(gText, "\r", {})
    if  num_CR > 0 then
      gEOL = "\r"
    end
  end
end
--]]

-- limited text
gLim_text = string.sub(gText, 1, gMax_text_len)

if not my_dofile(gConfig_dir .. "spamfilter_config.lua") then
  -- flush everything and return error
  io.write(gText)
  io.flush()
  return 1
end

-- database definitions
local extra_delimiters = ""
if osbf.cfg_extra_delimiters then
  extra_delimiters = osbf.cfg_extra_delimiters
end

osbf.cfg_dbset = {
       classes = {gDatabase_dir .. osbf.cfg_nonspam_file,
                  gDatabase_dir .. osbf.cfg_spam_file},
       ncfs    = 1, -- split "classes" in 2 sublists. "ncfs" is
                    -- the number of classes in the first sublist.
       delimiters = extra_delimiters
    }
osbf.cfg_nonspam_index  = 1
osbf.cfg_spam_index     = 2

-- read white and black lists
if not my_dofile(gLists_dir .. "whitelist.lua") then
  whitelist = {}
elseif type(whitelist) ~= "table" then
  whitelist = {}
end
if not my_dofile(gLists_dir .. "blacklist.lua") then
  blacklist = {}
elseif type(blacklist) ~= "table" then
  blacklist = {}
end

-- log incoming messages
if (osbf.cfg_log_incoming) then
  spamfilter_log(gText, gUser_log_dir .. "spamfilter_inbox") 
end

-- extract header and header indexes
gHeader, header_end = string.match(gText, "^(.-()\n)\n")
local header_start = 1
if not gHeader then
  if string.sub(gText, -1) == "\n" then
    gHeader = gText
    gText = gText .. "\n"
  else
    gHeader = gText .. "\n"
    gText = gText .. "\n\n"
  end
  header_end = string.len(gText) - 1
end
-- body starts at the new-line that marks the end of the header
local body_start = header_end + 1

if command_line then
  -- fill in the command structure with the command line args and
  -- flag that the message for training comes from stdin
  if gOptions["learn"] then
    cmd = "learn"
    if gOptions["source"] == nil or gOptions["source"] == "stdin" then
      cmd_args = " " .. gOptions["learn"] .. " stdin"
    elseif gOptions["source"] == "body" then
      cmd_args = " " .. gOptions["learn"] .. " body"
    elseif gOptions["source"] == "sfid" then
      cmd_args = " " .. gOptions["learn"]
    end
  elseif gOptions["unlearn"] then
    cmd = "unlearn"
    if gOptions["source"] == nil or gOptions["source"] == "stdin" then
      cmd_args = " " .. gOptions["unlearn"] .. " stdin"
    elseif gOptions["source"] == "body" then
      cmd_args = " " .. gOptions["unlearn"] .. " body"
    elseif gOptions["source"] == "sfid" then
      cmd_args = " " .. gOptions["unlearn"]
    end
  end
else
  -- check if we have a command in the subject field
  cmd, cmd_args = string.match(gHeader,
    "\n[Ss][Uu][Bb][Jj][Ee][Cc][Tt][ \t]-:[ \t]*([%a_]+)[ %+]" ..
	osbf.cfg_pwd .. "(.-)\n[^ \t]")

  if (cmd_args) then
    cmd_args = string.gsub(cmd_args, "\n([ \t])", "%1")
  end

  -- if not found in the subject, check the first lines of the body
  if (not cmd) then
    cmd, cmd_args = string.match(
	string.sub(gText, body_start, body_start + 100),
	"\n%s-(%a+)[ %+]" .. osbf.cfg_pwd .. "([^\n]*)\n")
  end
end

-- spamfilter command?
if (cmd and ((osbf.cfg_pwd ~= "your_password_here") or command_line) and
    (string.match(cmd_args, "^%s") or cmd_args == "")) then
  -- almost sure a command was found, try to execute it.
  if my_dofile(gGlobal_osbf_dir .. "spamfilter_commands.lua") then
    valid_command, command_result, result_header, result_body =
	process_command(cmd, cmd_args)
  else
    spamfilter_log("ERROR: " .. gGlobal_osbf_dir ..
		   "spamfilter_commands.lua not found\n",
			gError_log_file, true) 
  end
end

--[[
command_result[1] => error message
command_result[2] => nil, "spam" or "ham"
command_result[3] => nil or old_pR
command_result[4] => nil or new_pR
--]]

if valid_command then
  if not (osbf.cfg_output == "message" and command_result[2]) then
    gHeader = gHeader .. string.format(
			"X-OSBF-Lua-Version: v%s Spamfilter v%s\n",
                        osbf._VERSION, gSf_version)
    if command_result then
      -- change subject line - append an extra "\n" for the search
      gHeader = string.gsub(gHeader .. "\n",
    	"\n[Ss][Uu][Bb][Jj][Ee][Cc][Tt][ \t]*:.-\n([^ \t])",
	"\nSubject: " ..
	command_result[1] .. "\n%1", 1)
      -- remove extra \n added for gsub
      gHeader = string.sub(gHeader,1, -2)
    end
    if result_body then
      io.write(gHeader, "\n", result_body)
    else
      io.write(gHeader, "\n", gBody)
    end
  else
    if command_result[2] and result_header and result_body then
      local trained_as = ""
      local subj_tag, sfid_tag
      if command_result[2] == "spam" then
	trained_as = "TS"
	subj_tag = osbf.cfg_tag_spam
	sfid_tag = "S"
      elseif command_result[2] == "ham" then
	trained_as = "TH"
	subj_tag = osbf.cfg_tag_ham
	sfid_tag = "H"
      else
	trained_as = ""
	subj_tag = ""
	sfid_tag = "E"
      end
      if command_result[3] == command_result[4] then
        trained_as = "TU"
      end
      local osbf_lua_header = string.format(
        "X-OSBF-Lua-Score: %.2f/%.2f [%s] %s (v%s, Spamfilter v%s)\n",
        command_result[4], osbf.cfg_min_pR_success, sfid_tag, trained_as,
	osbf._VERSION, gSf_version)
      classified_header =  tag_subject(result_header .. osbf_lua_header,
				 	subj_tag)
      io.write(classified_header .. result_body)
    else
      io.write(command_result[1] .. '\n')
    end
  end
else
  -- no command found, classify the message
  -- sfid_tag will be set one of "W", "B", "E", "S", "H", "-" or "+"
  sfid_tag = ""
  subj_tag = ""
  pR = nil

  -- check white and black lists
  -- check special train report whitelist
local search_header = "\n" .. gHeader
local _, n = string.gsub(search_header,
		"\nX%-Spamfilter%-Lua%-Whitelist: " .. osbf.cfg_pwd, "")
  if n > 0 then
     subj_tag = osbf.cfg_tag_ham
     sfid_tag = "W"
  else
    for _, w in ipairs(whitelist) do
      if string.find(search_header, w, 1, not osbf.cfg_lists_use_regex) then
        subj_tag = osbf.cfg_tag_ham
        sfid_tag = "W"
        break
      end
    end

    if sfid_tag == "" then
      for _, b in ipairs(blacklist) do
        if string.find(search_header, b, 1, not osbf.cfg_lists_use_regex) then
          subj_tag = osbf.cfg_tag_spam
          sfid_tag = "B"
          break
        end
      end
    end
  end

  local count_classifications_flag = 0
  if osbf.cfg_count_classifications then
    count_classifications_flag = 2
  end

  pR, class_probs, _, gTrainings = osbf.classify(gLim_text, osbf.cfg_dbset,
	 count_classifications_flag + osbf.cfg_classify_flags)

  if (pR == nil) then
     -- log error message
     spamfilter_log(class_probs, gError_log_file, true)
  end

  if sfid_tag == "" then
    subj_tag, sfid_tag = get_tags(pR)
  end

  local osbf_lua_header = string.format(
       "X-OSBF-Lua-Score: %.2f/%.2f [%s] (v%s, Spamfilter v%s)\n",
       pR or 0, osbf.cfg_min_pR_success, sfid_tag, osbf._VERSION, gSf_version)

  classified_header = gHeader .. osbf_lua_header

  if gOptions["classify"] then
    io.write(osbf_lua_header)
    return
  elseif gOptions["score"] then
    if pR then
      io.write(string.format("%.2f\n", pR))
    else
      io.write("Classification error: ", class_probs)
    end
    return
  else
    classified_header = tag_subject(classified_header, subj_tag)
  end

  -- create a spamfilter ID
  -- use user defined right ID if available
  if (osbf.cfg_rightid) then
    rightid = "@" .. osbf.cfg_rightid
  else
    rightid = "@spamfilter.osbf.lua"
  end

  local sfid_date = os.date("%Y%m%d-%H%M%S")
  local  sfid_subdir = ""
  if osbf.cfg_use_sfid_subdir then
    sfid_subdir = string.sub(sfid_date, 7, 8) .. "/" ..
          string.sub(sfid_date, 10, 11) .. "/"
  end

  local leftid = string.format("sfid-%s%s-%+07.2f-", sfid_tag,
				 sfid_date, pR or 0)
  leftid_idx = 1
  sfid = leftid .. tostring(leftid_idx) .. rightid

  while leftid_idx < 1000 and
        file_exists(gUser_cache_dir .. sfid_subdir .. sfid) do
    leftid_idx = leftid_idx + 1
    sfid = leftid .. tostring(leftid_idx) .. rightid
  end

  -- Do we want SFID and have a valid one?
  if not osbf.cfg_dont_use_sfid and leftid_idx < 10000 then
    classified_header = insert_sfid(classified_header, sfid,
	osbf.cfg_insert_sfid_in)
    -- save the original message for future training
    if osbf.cfg_save_for_training then
      spamfilter_log(gText, gUser_cache_dir .. sfid_subdir .. sfid) 
    end
  end

  -- output the classified message
  if type(osbf.cfg_remove_body_threshold) == "number" and
     sfid_tag ~= "W" and pR and
     (pR < osbf.cfg_remove_body_threshold or sfid_tag == "B") then
    classified_header = string.gsub(classified_header,
         "\n[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Tt][Yy][Pp][Ee][ \t]-:.-\n([^ \t])",
	 "\n%1")
    io.write(classified_header, "\n*** Body Removed by Spamfilter ***\n\n", 
	"Reply to yourself with the command \"recover <pwd>\" in the\n",
	"subject to recover the original message as an attachment.\n")
  else
    io.write(classified_header, string.sub(gText, body_start))
  end
  io.flush()

end

