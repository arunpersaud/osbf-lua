#! /usr/local/bin/lua
-- Process spamfilter commands
-- Copyright (C) 2005, 2006, 2007 Fidelis Assis <fidelis@pobox.com>

local mail_cmd = osbf.cfg_mail_cmd or "/usr/lib/sendmail -it < "

local classify_flags            = 0
local count_classification_flag = 2
local learn_flags               = 0
local mistake_flag              = 2
local reinforcement_flag        = 4

-- experimental constants
local threshold_offset			= 2
local max_learn_threshold		= 20 -- overtraining protection
local header_learn_threshold            = 14 -- header overtraining protection
local reinforcement_degree              = 0.6
local ham_reinforcement_limit           = 4
local spam_reinforcement_limit          = 4
local threshold_reinforcement_degree    = 1.5

-- don't use sfid subdir, unless specified in the config file
local  sfid_subdir = ""

function get_sfid_subdir(sfid)
  local  sfid_subdir = ""
  if osbf.cfg_use_sfid_subdir then
    sfid_subdir = string.sub(sfid, 13, 14) .. "/" ..
		 string.sub(sfid, 16, 17) .. "/"
    return sfid_subdir
  else
    return ""
  end
end

function help()
  local f = io.open(gGlobal_osbf_dir .. "spamfilter.help", "r")
  if (f) then
    local help_txt = f:read("*all")
    f:close()
    return string.format(help_txt, osbf.cfg_tag_spam, osbf.cfg_tag_unsure_spam,
                       osbf.cfg_tag_unsure_ham, osbf.cfg_tag_ham,
		       osbf.cfg_threshold, osbf.cfg_threshold,
		       osbf.cfg_min_pR_success, osbf._VERSION, gSf_version)
  else
    local err_msg = "Help file not found (" .. gGlobal_osbf_dir ..
		    "spamfilter.help)\n"
    spamfilter_log(err_msg, error_log_file, true)
    return "Help file not found.\n"
  end
end

-- escape lua regex characters
function escape_regchars(str)
  local s
  s = string.gsub(str, "%%", "%%%%")
  s = string.gsub(s, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  return s
end


-- escape special chars
function escape_schars(s)
  s = string.gsub(s, "\\", "\\\\")
  s = string.gsub(s, '"', '\\"')
  s = string.gsub(s, "'", "\\'")
  s = string.gsub(s, "\n", "\\n")
  s = string.gsub(s, "\t", "\\t")
  s = string.gsub(s, "\r", "\\r")
  return (s)
end

-- unescape special chars
function unescape_schars(s)
  s = "x" .. s
  s = string.gsub(s, '\\"', '"')
  s = string.gsub(s, "\\'", "'")
  s = string.gsub(s, "([^\\])\\n", "%1\n")
  s = string.gsub(s, "([^\\])\\t", "%1\t")
  s = string.gsub(s, "([^\\])\\r", "%1\r")
  s = string.gsub(s, "\\\\", "\\")
  return (string.sub(s,2))
end

-- for case insensitive match - from PIL
function nocase (s)
  s = string.gsub(s, "%a", function (c)
        return string.format("[%s%s]", string.lower(c),
                                       string.upper(c))
      end)
  return s
end

-- remove unwanted headers
function clean_header(header, unwanted_headers)
  for _, h in ipairs(unwanted_headers) do
    if (h ~= "") then
      -- h = escape_regchars(h)
      h = nocase(h)
      repeat
        header, count = string.gsub(header, "\n" .. h .. ".-(\n[^ \t])", "%1")
      until count == 0
    end
  end
  return header
end

-- save a list
function list_save(list, listname)
  local file = gLists_dir .. listname .. ".lua"
  local w = io.open(file, "w")
  if (w) then
    w:write(listname, " = {")
    local list_contents = ""
    for _, e in ipairs(list) do
      e = escape_schars(e)
      if list_contents == "" then
        list_contents = '"' .. e .. '"'
      else
        list_contents = list_contents .. ',\n"' .. e .. '"'
      end
    end
    if list_contents == '' then
      w:write('}\n')
    else
      w:write('\n', list_contents, '\n}\n')
    end
    w:close()
  else
    return nil, "can't open listname for writing"
  end
  return true
end

-- return a string with the list contents
function list_sprint(list, listname)
  local list_string
  list_string = ""
  if list and listname then
        list_string = "--- start of " .. listname .. " ---\n"
        for _, v in ipairs (list) do
	  v = escape_schars(v)
          list_string = list_string .. v .. "\n"
        end
        list_string = list_string .. "--- end of " .. listname .. " ---\n"
  else
  	list_string = nil, "invalid list or listname"
  end
  return  list_string
end

-- insert element into a list (black or white) and save the list
function list_insert(element, list, listname)
  if (element and list and listname) then
    for _, v in ipairs(list) do
      if v == element then
        return nil, "Already in the list"
      end
    end
    table.insert(list, element)
    -- save the list
    return list_save(list, listname)
  else
    return nil, "Invalid argument"
  end
end

-- delete element from a list (black or white) and save the list
function list_delete(element, list, listname)
  local found = false
  if (element and list and listname) then
     for i, e in ipairs(list) do
       if e == element then
          table.remove(list, i)
	  found = true
       end
     end
     -- save the list
     if found then
       return list_save(list, listname)
     else
       return nil, "Element not found in the " .. listname
     end
  else
    return nil, "Invalid element or list"
  end
end

-- returns a string report with dbfile statistics
function classes_stats(classes)
    local version = "OSBF-Bayes"
    local error_rate1, error_rate2, global_error_rate, spam_rate
    local stats1 = osbf.stats(classes[osbf.cfg_nonspam_index])
    local stats2 = osbf.stats(classes[osbf.cfg_spam_index])

    local report = "Statistics for " ..
		    string.gsub(classes[osbf.cfg_nonspam_index], ".*/", "") ..
		    ":\n" ..
		    string.rep("-", 47) .. "\n"

    if (stats1.version == 5 and stats2.version == 5) then


      report = report .. string.format(
        "%-35s%12s\n%-35s%12d\n%-35s%12.1f\n%-35s%12d\n%-35s%12d\n",
        "Database version:", version,
        "Total buckets in database:", stats1.buckets,
        "Buckets used (%):", stats1.use * 100,
        "Bucket size (bytes):", stats1.bucket_size,
        "Header size (bytes):", stats1.header_size)

      report = report .. string.format(
        "%-35s%12d\n%-35s%12d\n" ..
        "%-35s%12.1f\n%-35s%12d\n%-35s%12d\n%-35s%12d\n",
        "Number of chains:", stats1.chains,
        "Max chain len (buckets):", stats1.max_chain,
        "Average chain length (buckets):", stats1.avg_chain,
        "Max bucket displacement:", stats1.max_displacement,
        "Buckets unreachable:", stats1.unreachable,
        "Trainings:", stats1.learnings)

      if stats1.classifications and stats2.classifications then
        if stats1.classifications + stats1.mistakes - stats2.mistakes > 0 then
          error_rate1 = stats1.mistakes /
	   (stats1.classifications + stats1.mistakes - stats2.mistakes)
        else
          error_rate1 = 0
        end
        report = report .. string.format(
	  "%-35s%12.0f\n%-35s%12d\n%-35s%12d\n%-35s%12.2f\n",
          "Classifications:", stats1.classifications,
          "Learned mistakes:", stats1.mistakes,
          "Extra learnings:", stats1.extra_learnings,
          "Ham accuracy (%):", (1 - error_rate1) * 100)
      end

      report = report .. string.rep("-", 47)

      report = report .. "\n\nStatistics for " ..
		    string.gsub(classes[osbf.cfg_spam_index],
		    ".*/", "") .. ":\n" ..
		    string.rep("-", 47) .. "\n"
      report = report .. string.format(
        "%-35s%12s\n%-35s%12d\n%-35s%12.1f\n%-35s%12d\n%-35s%12d\n",
        "Database version:", version,
        "Total buckets in database:", stats2.buckets,
        "Buckets used (%):", stats2.use * 100,
        "Bucket size (bytes):", stats2.bucket_size,
        "Header size (bytes):", stats2.header_size)

      report = report .. string.format(
        "%-35s%12d\n%-35s%12d\n" ..
        "%-35s%12.1f\n%-35s%12d\n%-35s%12d\n%-35s%12d\n",
        "Number of chains:", stats2.chains,
        "Max chain len (buckets):", stats2.max_chain,
        "Average chain length (buckets):", stats2.avg_chain,
        "Max bucket displacement:", stats2.max_displacement,
        "Buckets unreachable:", stats2.unreachable,
        "Trainings:", stats2.learnings)

      if stats1.classifications and stats2.classifications then
        if stats2.classifications + stats2.mistakes - stats1.mistakes > 0 then
          error_rate2 = stats2.mistakes /
	   (stats2.classifications + stats2.mistakes - stats1.mistakes)
        else
          error_rate2 = 0
        end

        report = report .. string.format(
	  "%-35s%12.0f\n%-35s%12d\n%-35s%12d\n%-35s%12.2f\n",
          "Classifications:", stats2.classifications,
          "Learned mistakes:", stats2.mistakes,
          "Extra learnings:", stats2.extra_learnings,
          "Spam accuracy (%):", (1 - error_rate2) * 100)
      end

      report = report .. string.rep("-", 47)

      if stats1.classifications + stats2.classifications > 0 then
	spam_rate = (stats2.classifications+stats2.mistakes-stats1.mistakes)/ 
	     (stats1.classifications+stats2.classifications)
      else
	spam_rate = 0
      end

      if stats1.classifications + stats2.classifications > 0 then
        global_error_rate = (stats1.mistakes + stats2.mistakes) /
	 (stats1.classifications + stats2.classifications)
      else
        global_error_rate = 0
      end

      report = report .. string.format(
	"\n%-35s%12.2f\n%-35s%12.2f\n%s\n\n",
	"Spam rate (%):", spam_rate * 100,
	"Global accuracy (%):", (1 - global_error_rate) * 100,
        string.rep("-", 47))
    else
        report = report .. string.format("%-35s%12s\n\n",
		 "Database version unknown: ", stats1.version)
    end

  return report
end

-- train "msg" as belonging to class "class_index"
-- return result (true or false), new_pR, old_pR or
--        nil, error_msg
-- true means there was a training, false indicates that the
-- training was not necessary
function osbf_train(msg, class_index)

  local lim_msg = string.sub(msg, 1, gMax_text_len)
  local pR, msg_error = osbf.classify(lim_msg, osbf.cfg_dbset, 0)

  if (pR) then
    if ( ( (pR < 0)  and (class_index == osbf.cfg_nonspam_index) ) or
         ( (pR >= 0) and (class_index == osbf.cfg_spam_index))   ) then

      -- approximate count. there could be cases where there was no mistake
      -- in the first classification, but just a change in classification
      -- because ot other trainings - and vice versa.
      osbf.learn(lim_msg, osbf.cfg_dbset, class_index, mistake_flag)
      if (osbf.cfg_log_learned) then
        spamfilter_log(msg, gUser_log_dir ..
			string.format("learned_as_class_%d.log", class_index)) 
      end
      local new_pR, msg_error = osbf.classify(lim_msg, osbf.cfg_dbset, 0)
      if new_pR then
        return true, new_pR, pR 
      else
	return nil, msg_error
      end
    elseif math.abs(pR) < max_learn_threshold then
      osbf.learn(lim_msg, osbf.cfg_dbset, class_index, 0)
      if (osbf.cfg_log_learned) then
        spamfilter_log(msg, gUser_log_dir ..
			string.format("learned_as_class_%d.log", class_index)) 
      end
      local new_pR, msg_error = osbf.classify(lim_msg, osbf.cfg_dbset, 0)
      if new_pR then
        return true, new_pR, pR 
      else
	return nil, msg_error
      end
    else
      return false, pR, pR
    end
  else
    return nil, msg_error
  end
end

-- send a message using a tmp file. os.popen may not be available
function send_message(message)
  local tmpfile = gUser_log_dir .. string.match(os.tmpname(), "([^/]+)$")
  local i = 0
  local f
  while i < 10 do
    f = io.open(tmpfile, "r")
    if f then
      f:close()
      tmpfile = gUser_log_dir .. string.match(os.tmpname(), "([^/]+)$")
      i = i + 1
    else
      break
    end
  end
  if i < 10 then
    local tmp = io.open(tmpfile, "w")
    if tmp then
      tmp:write(message)
      tmp:close()
      os.execute(mail_cmd .. tmpfile)
      os.remove(tmpfile)
    end
  end
end

function process_command (cmd, cmd_args)
  local valid_command = true
  local orig_header, orig_body, orig_msg, lim_orig_msg, lim_orig_header
  local answer_body, answer_header
  local training_result
  local cache_filename
  local sfid

  -- extract args, if any
  local arg1, arg2 = string.match(cmd_args, "^%s*(%S+)%s*(.*)")

  if (cmd == "learn" or cmd == "unlearn" or cmd == "recover" or
      cmd == "classify") then

    -- Remove content-type to avoid conflicts with the to-be-inserted body
    gHeader = clean_header(gHeader, {"Content%-Type:"})

    -- try to find the sfid to recover the original message
    if (arg2 and string.match(arg2, "sfid%-")) then
      sfid = arg2
    elseif (arg1 and string.match(arg1, "sfid%-")) then
      sfid = arg1
    elseif arg2 == "body" or arg1 == "body" then
      sfid = "body"
    elseif arg2 == "stdin" or arg1 == "stdin" then
      sfid = "stdin"
    end

    if (not sfid) then
      -- if the sfid was not given in the command, extract it
      -- from the references or in-reply-to field

      -- new method, look it up in the references field first
      local references = string.match(gHeader .. "\n",
	 "\n[Re][Ee][Ff][Ee][Rr][Ee][Nn][Cc][Ee][Ss][ \t]-:(.-)\n[^ \t]")
      if references then
	-- match the last sfid in the field
        sfid = string.match(references, ".*<(sfid%-.-)>")
      end

      -- if not found as a reference, try as a comment in In-Reply-To
      if not sfid then
        sfid = string.match(gHeader .. "\n",
         "\n[Ii][Nn]%-[Rr][Ee][Pp][Ll][Yy]%-[Tt][Oo][ \t]-:.-%((sfid%-.-)%)\n[^ \t]")
      -- if not found in the "In-Reply-To", try a comment in "References"
        if not sfid then
          sfid = string.match(gHeader .. "\n",
           "\n[Re][Ee][Ff][Ee][Rr][Ee][Nn][Cc][Ee][Ss][ \t]-:.-%((sfid%-.-)%)\n[^ \t]")
        end
      end
    end

    -- recover original header and body
    if sfid then

      if sfid == "stdin" then
	orig_msg = gText
	orig_header, orig_body = string.match(gText, "^(.-\n\n)(.*)")
	if not orig_header then
	  orig_header = gText
	end
        -- add a space to avoid a "From ..." at the beginning
	answer_body = " " .. orig_header
      elseif sfid == "body" then
        -- extract the original message from the body and clean it
        orig_header, orig_body = string.match(gText, "^.-\n\n%s*(.-\n\n)(.*)")

	-- remove old syntax command, if any
	orig_header = string.gsub(orig_header, "^%s*command " ..
						osbf.cfg_pwd .. ".-\n", "", 1)
	-- remove subject tags
	local subj_header = nocase("(\nSubject[ \t]-: )")
        orig_header = string.gsub(orig_header,
         subj_header .. escape_regchars(osbf.cfg_tag_unsure_spam), "%1")
        orig_header = string.gsub(orig_header,
         subj_header .. escape_regchars(osbf.cfg_tag_unsure_ham), "%1")
        orig_header = string.gsub(orig_header,
         subj_header .. escape_regchars(osbf.cfg_tag_spam), "%1")
        orig_header = string.gsub(orig_header,
         subj_header .. escape_regchars(osbf.cfg_tag_ham), "%1")
        orig_header = string.gsub(orig_header,
          "\n%s-%(sfid.-@" .. escape_regchars(osbf.cfg_rightid) .. "%)",
	  "")
        orig_header = string.gsub(orig_header,
          "<sfid.-@" .. escape_regchars(osbf.cfg_rightid) .. ">\n",
	  "\n")

	local i
	-- the "repeat" is needed here despite the "gsub"
	repeat
          orig_header, i = string.gsub(orig_header,
		 "\nX%-OSBF%-.-(\n[^ \t])", "%1")
	until i == 0

        orig_msg = orig_header .. orig_body
        answer_body = orig_header
      else
	-- recover message from cache
	sfid_subdir = get_sfid_subdir(sfid)
	local f
	cache_filename = gUser_cache_dir .. sfid_subdir .. sfid
	if cmd == "learn" then 
          f = io.open(cache_filename, "r")
	elseif cmd == "unlearn" then
	  if arg1 == "spam" then
            f = io.open(cache_filename .. "-s", "r")
	  elseif arg1 == "nonspam" or arg1 == "ham" then
            f = io.open(cache_filename .. "-h", "r")
	  end
	else
          f = io.open(cache_filename, "r")
	  if not f then
            f = io.open(cache_filename .. "-s", "r")
	  end
	  if not f then
            f = io.open(cache_filename .. "-h", "r")
	  end
	end
        if (f) then
          orig_msg = f:read("*all")
	  orig_header, orig_body = string.match(orig_msg, "^(.-\n)(\n.*)")
	  answer_body = " " .. orig_header
          f:close()
        else
	  cache_filename = nil
          training_result = {"Original message not available any more "}
	  answer_body = [[
Copies of the original messages are kept for a few days on the
server for training purposes. Probably the message you are trying
to train with has already been deleted.

Another possibility is that you've sent an invalid command, that is,
you can not train with the same message more than once, unless you
undo (unlearn) the previous training, nor unlearn what was not
previously learned.

Try with a recent message, for instance one you received today,
to check the training mechanism. You may use the "recover" command,
instead of "learn" or "unlearn", for just checking if the message
is there.

The Spam Filter ID of the missing message is:

 SFID: ]] .. sfid .. "\n"

          return true, training_result, answer_header, answer_body
        end
      end
    else
      training_result = {"Spamfilter ID (SFID) not found"}
      answer_body = [[
The possible reasons why a SFID isn't found:
- You didn't use the "Reply" facility of your email client;
- The message wasn't previously classified by the spamfilter;
- A bug in the spamfilter.

If you are sure about the first two possibilities, ask your
email system administrator for support.
]]
      return true, training_result, answer_header, answer_body
    end

    lim_orig_msg = string.sub(orig_msg, 1, gMax_text_len)
    lim_orig_header = string.sub(orig_header, 1, gMax_text_len)

    if (cmd == "learn") then
        if (arg1 == "spam") then
          local r, new_pR, orig_pR = osbf_train(orig_msg, osbf.cfg_spam_index)
	  if r then
            if new_pR > (threshold_offset - osbf.cfg_threshold) and
               (orig_pR - new_pR) < header_learn_threshold then
              local i = 0, pR
              local trd = threshold_reinforcement_degree *
                          (threshold_offset - max_learn_threshold)
              local rd = reinforcement_degree * header_learn_threshold
              repeat
                pR = new_pR
                osbf.learn(lim_orig_header, osbf.cfg_dbset,
                           osbf.cfg_spam_index,
                           osbf.cfg_learn_flags+reinforcement_flag)
                new_pR, p_array = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                  osbf.cfg_classify_flags)
                i = i + 1
              until i >= spam_reinforcement_limit or
	  	    new_pR < trd or (pR - new_pR) >= rd
            end

	    training_result = {osbf.cfg_trained_as_spam  ..
				  ": " .. string.format("%.2f", orig_pR) ..
				  " -> " .. string.format("%.2f", new_pR),
				"spam", orig_pR, new_pR}
	    if cache_filename then
	      os.rename(cache_filename, cache_filename .. "-s")
	    end
	  else
	    if r == nil then
	      training_result = {new_pR} -- new_pR contains error msg
	    else
 	      training_result = {string.format(osbf.cfg_training_not_necessary,
	  		new_pR, max_learn_threshold, max_learn_threshold),
			"spam", new_pR, new_pR}
	      if cache_filename then
	        os.rename(cache_filename, cache_filename .. "-s")
	      end
	    end
	  end

	  if osbf.cfg_output == "message" then
	    answer_header, answer_body = orig_header, orig_body
	  end

        elseif (arg1 == "nonspam" or arg1 == "ham") then

          local r, new_pR, orig_pR = osbf_train(orig_msg,
					 osbf.cfg_nonspam_index)
	  if r then
            if new_pR < (threshold_offset + osbf.cfg_threshold) and
               (new_pR - orig_pR) < header_learn_threshold then
              local i = 0, pR
              local trd = threshold_reinforcement_degree *
                          (threshold_offset + max_learn_threshold)
              local rd = reinforcement_degree * header_learn_threshold
              repeat
                pR = new_pR
                osbf.learn(lim_orig_header, osbf.cfg_dbset,
                           osbf.cfg_nonspam_index,
                           osbf.cfg_learn_flags+reinforcement_flag)
                new_pR, p_array = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                  osbf.cfg_classify_flags)
                i = i + 1
              until i > ham_reinforcement_limit or
	  	    new_pR > trd or (new_pR - pR) >= rd
            end

	    training_result = {osbf.cfg_trained_as_nonspam  ..
				 ": " .. string.format("%.2f", orig_pR) ..
				 " -> " .. string.format("%.2f", new_pR),
				"ham", orig_pR, new_pR}
	    if cache_filename then
	      os.rename(cache_filename, cache_filename .. "-h")
	    end
	  else
	    if r == nil then
	      training_result = {new_pR} -- new_pR contains error msg
	    else
 	      training_result = {string.format(osbf.cfg_training_not_necessary,
	  		new_pR, max_learn_threshold, max_learn_threshold),
			"ham", new_pR, new_pR}
	      if cache_filename then
	        os.rename(cache_filename, cache_filename .. "-h")
	      end
	    end
	  end

	  if osbf.cfg_output == "message" then
	    answer_header, answer_body = orig_header, orig_body
	  end

        else
          valid_command = false
        end

    elseif (cmd == "unlearn") then

       if (arg1 == "spam") then
	 local old_pR, _ = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                         osbf.cfg_classify_flags)
         osbf.unlearn(orig_msg, osbf.cfg_dbset, osbf.cfg_spam_index,
	     		osbf.cfg_learn_flags+mistake_flag)
	 local pR, _ = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                         osbf.cfg_classify_flags)
	 local i = 0
         while i < spam_reinforcement_limit and pR < threshold_offset do
           osbf.unlearn(lim_orig_header, osbf.cfg_dbset, osbf.cfg_spam_index,
	     		osbf.cfg_learn_flags)
	   pR, _ = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                         osbf.cfg_classify_flags)
	   i = i + 1
	 end
         training_result = {"Message unlearned as spam: " .. 
				string.format("%.2f", old_pR) ..
				" -> " .. string.format("%.2f", pR)}
	if cache_filename then
	  os.rename(cache_filename .. "-s", cache_filename)
	end
				
       elseif (arg1 == "nonspam") then

	 local old_pR, _ = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                         osbf.cfg_classify_flags)
         osbf.unlearn(orig_msg, osbf.cfg_dbset, osbf.cfg_nonspam_index,
			 osbf.cfg_learn_flags+mistake_flag)
	 local pR, _ = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                         osbf.cfg_classify_flags)
	 local i = 0
	 while i <  ham_reinforcement_limit and pR > threshold_offset do
           osbf.unlearn(lim_orig_header, osbf.cfg_dbset, osbf.cfg_nonspam_index,
			 osbf.cfg_learn_flags)
	   pR, _ = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
                                         osbf.cfg_classify_flags)
	   i = i + 1
	 end
         training_result = {"Message unlearned as nonspam: " ..
				string.format("%.2f", old_pR) ..
				" -> " .. string.format("%.2f", pR)}
	 if cache_filename then
	   os.rename(cache_filename .. "-h", cache_filename)
	 end
       else
         valid_command = false
       end

    elseif (cmd == "recover") then

      boundary = string.gsub(sfid, "@.*", "=-=-=", 1)

      -- alter original header!
      gHeader = clean_header(gHeader, {"Content%-Type:"})
      gHeader = string.gsub(gHeader,
        "\n[Cc][Oo][Nn][Tt][Ee][Nn][Tt]%-[Tt][Yy][Pp][Ee][ \t]-:.-\n([^ \t])",
	"\n%1", 1)
      gHeader = gHeader .. "Content-Type: multipart/mixed;\n" ..
         " boundary=\"" .. boundary .. "\"\n"

      training_result = {"The recovered message is attached"}

      -- protect and keep the original envelope-from line
      local xooef = ""
      if string.match(orig_msg, "^From ") then
        xooef = "X-OSBF-Original-Envelope-From:\n\t"
      end

      answer_body = "--" .. boundary ..
         "\nContent-Type: message/rfc822;\n" ..
         " name=\"Recovered Message\"\n" ..
         "Content-Transfer-Encoding: 8bit\n" ..
         "Content-Disposition: inline;\n" ..
         " filename=\"Recovered Message\"\n\n" ..
         xooef .. orig_msg ..
         "\n--" .. boundary .. "--\n"

    elseif (cmd == "classify") then
      gHeader = clean_header(gHeader, {"Content%-Type:"})
      pR, class_probs = osbf.classify(lim_orig_msg, osbf.cfg_dbset,
					 osbf.cfg_classify_flags)
      training_result = {"pR = " .. string.format("%.4f", pR)}
    end

  elseif (cmd == "whitelist" or cmd == "blacklist") then
    gHeader = clean_header(gHeader, {"Content%-Type:"})
    if (arg1 == "add" or arg1 == "del") then
      local result, msg_err
      local unesc_arg2 = unescape_schars(arg2)
      if arg1 == "add" then
        if cmd == "whitelist" then
          result, msg_err = list_insert(unesc_arg2, whitelist, cmd)
        else
          result, msg_err = list_insert(unesc_arg2, blacklist, cmd)
	end
      else
        if cmd == "whitelist" then
          result, msg_err = list_delete(unesc_arg2, whitelist, cmd)
        else
          result, msg_err = list_delete(unesc_arg2, blacklist, cmd)
	end
      end
      if not result then
        training_result = {"Error: " .. msg_err}
	answer_body = ""
      else
        training_result = {cmd .. " " .. arg1 .. " " .. arg2}
        if cmd == "whitelist" then
          answer_body = list_sprint(whitelist, "whitelist")
        else
          answer_body = list_sprint(blacklist, "blacklist")
        end
      end
    elseif (arg1 == "show") then
      gHeader = clean_header(gHeader, {"Content%-Type:"})
      training_result = {cmd .. " " .. "contents"}
      if cmd == "whitelist" then
        answer_body = list_sprint(whitelist, "whitelist")
      else
        answer_body = list_sprint(blacklist, "blacklist")
      end
    else 
      gHeader = clean_header(gHeader, {"Content%-Type:"})
      training_result = {"Unknown command"}
      answer_body =  cmd .. " <password> " .. cmd_args
    end

  elseif (cmd == "stats") then
    gHeader = clean_header(gHeader, {"Content%-Type:"})
    training_result = {"OSBF-Lua database statistics"}
    answer_body = classes_stats(osbf.cfg_dbset.classes)

  elseif (cmd == "batch_train") then
    -- extract sfids and actions from the body and process them
    local batch_result = ""
    local whitelist_changed = false

    local email = string.match(gHeader, nocase("To") .. "%s-:%s-(.-)\n")
    if email then
      osbf.cfg_output = "report"

      -- batch_train loop
      for sfid, action in string.gmatch(gText, "\n(sfid%-.-)=([^\n]+)") do
        local subject = nil
	cache_filename = gUser_cache_dir .. get_sfid_subdir(sfid) .. sfid

        if action == "spam" or action == "nonspam" then
	  if string.match(sfid, "^sfid%-[Hu]") or action == "spam" then
	    local valid_command, command_result, result_header, result_body =
		process_command("learn", action .. " " .. sfid)
	    batch_result = batch_result .. sfid .. ": " ..
				command_result[1] .. "\n"
	  else
	    subject = "learn " .. osbf.cfg_pwd .. " " .. action .. " " .. sfid
	    batch_result = batch_result .. sfid .. ": " ..
			   "A new copy of the message will be sent with the " ..
			   "right classification\n"
	  end

	elseif action == "whitelist_from" or action == "whitelist_subject" then
	  local header_name = "From"
	  if action == "whitelist_subject" then
	    header_name = "Subject"
	  end
          local  f = io.open(cache_filename, "r")
	  if (not f) then f = io.open(cache_filename .. "-h", "r") end
	  if (not f) then f = io.open(cache_filename .. "-s", "r") end
          if (f) then
            local msg = f:read("*all")
            local headers = string.match(msg, "^(.-\n)\n")

	    -- fix broken header
	    if not headers then
	      if string.sub(msg, -1) == "\n" then
		headers = msg
		msg = msg .. "\n"
	      else
		headers = msg .. "\n"
		msg = msg .. "\n\n"
	      end
	    end
	
	    local header_line = string.match("\n" .. headers,
			"\n(" .. nocase(header_name) ..
			"[ \t]*:[ \t]*[^\n]+)\n")
	    if header_line then
	      header_line = unescape_schars(header_line)
	      if osbf.cfg_lists_use_regex then
		header_line = escape_regchars(header_line)
	      end
	      local r, msg_err = list_insert("\n" .. header_line .. "\n",
			 whitelist, "whitelist")
	      if r then
	        batch_result = batch_result .. sfid .. ": '" .. header_name ..
				"' added to whitelist\n"
		whitelist_changed = true
	      else
	        batch_result = batch_result .. "'" .. header_line ..
				"': " .. msg_err .. "\n"
	      end
	    end
            f:close()
	  else
	    batch_result = batch_result .. sfid .. 
			   ": original message not available any more\n"
	  end

	elseif action == "recover" then
	  subject = "recover " .. osbf.cfg_pwd .. " " .. sfid
	  if file_exists(cache_filename) then
	    subject = "recover " .. osbf.cfg_pwd .. " " .. sfid
	    batch_result = batch_result .. sfid .. ": recover command sent\n"
	  else
	    batch_result = batch_result .. sfid ..
                         ": original message not available any more\n"
	  end

	elseif action == "remove" then
	  if file_exists(cache_filename) then
	    os.remove(cache_filename)
	    batch_result = batch_result .. sfid .. ": removed\n"
	  else
	    batch_result = batch_result .. sfid .. 
			   ": original message not available any more\n"
	  end

	elseif action == "undo" then
	  local class
	  if file_exists(cache_filename .. "-s") then
	    class = "spam"
	  elseif file_exists(cache_filename .. "-h") then
	    class = "nonspam"
	  end
	  if class then
	    local valid_command, command_result, result_header, result_body =
	      process_command("unlearn", class .. " " .. sfid)
	      batch_result = batch_result .. sfid .. ": " ..
				command_result[1] .. "\n"
	  else
	      batch_result = batch_result .. sfid .. ": can't undo what was not done\n"
	  end
        end

        if subject then
	  if file_exists(cache_filename) or 
		file_exists(cache_filename .. "-s") or
		file_exists(cache_filename .. "-h") then
	    local train_msg = "From: " .. email .. "\nTo: " .. email ..
			"\nSubject: " .. subject .. "\n\n "
            send_message(train_msg)
	  end
        end
      end

      if whitelist_changed then
        batch_result = batch_result .. 
		list_sprint(whitelist, "whitelist").. "\n"
      end
      gHeader = clean_header(gHeader, {"Content%-Type:"})
      training_result = {"Batch training results"}
      answer_body = [[
The training commands have been sent. Non spam messages previously
classified as spam or with a low non-spam score (tagged with [+])
will be sent again, after trained, with the right classification.

]] .. batch_result 
    else
    end
  elseif (cmd == "train_form") then
    local email = string.match(gHeader, nocase("To") .. "%s-:%s-(.-)\n")
    if email then
      os.execute(gGlobal_osbf_dir .. "cache_report.lua '" .. 
		gUser_osbf_dir .. "' '" .. email .. "'")
      osbf.cfg_output = "report"
      training_result = {"Report command result"}
      answer_body = "The training form will be sent to you.\n"
    else
      osbf.cfg_output = "report"
      training_result = {"Train-form command result"}
      answer_body = [[Error, the "To:" field was not found.]]
    end
  elseif (cmd == "help") then
    gHeader = clean_header(gHeader, {"Content%-Type:"})
    training_result = {"spamfilter help"}
    answer_body = help()
  else
    valid_command = false
  end

  return valid_command, training_result, answer_header, answer_body
end

