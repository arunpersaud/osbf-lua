#!/usr/local/bin/lua
-- Script for training with TREC compatible corpora
-- Version: v1.3 - Aug/2006 - Fidelis Assis 

-- DSTTT is not used any more. An SSTTT variant is used instead where
-- extra learnings, using only the header, are done when the previous
-- was not enough. In general, this variant results in better accuracy
-- and now is the default training method.
--
-- TOE (Train On Error) can still be used if both "threshold"
-- and "header_learn_threshold" are set to 0, but normally SSTTT is
-- much better than TOE.
--
-- See the on-line book "The CRM114 Discriminator Revealed!" by
-- William S. Yerazunis for the definitions of TOE, SSTTT and DSTTT.
-- There's a link to the book on http://crm114.sourceforge.net.

-- TOER means TOE + Reinforcements, another name for SSTTT. TONE -
-- Train On or Near Error - is yet another name I sometimes refer to
-- it as.

--[[------------------------------------------------------------------

This program is free software. You can use it as you want.
As usual, without warranty of any kind. Use it at your own risk.

How to use:

$ ./toer.lua <path_to_index> [<index_name>]

The index file is a list of message files with two fields separated
by a space per line. The first field is the judge ("spam" or "ham")
and the second is the message filename, relative to <path_to_index>.

Ex:

spam ../data/message001
ham ../data/message002
ham ../data/message003
spam ../data/message004
...

In this example, the message files are in a dir named "data", parallel
to <path_to_index>.

OBS: toer.lua doesn't affect the counters used for accuracy statistics.

--]]----------------------------------------------------------------

-- start of program

local osbf = require "osbf"  -- load osbf module
local string = string
local math = math

local threshold_offset  = 5  -- [-5, +5]
			     -- -5 => less false negatives
			     --  0 => normal
			     -- +5 => less false positives
local delimiters	= "" -- token delimiters
--local delimiters	= ".@:/"
local num_buckets	= 94321 -- min value recommended for production
--local num_buckets	= 4000037 -- value used for TREC tests
local preserve_db       = false -- preserve databases or not between corpora
local max_text_size     = 500000 -- 0 means full document
local min_p_ratio       = 1  -- minimum probability ratio over the classes a
			     -- feature must have so as not to be ignored
local corpora_dir	= "./" -- default = local dir
local corpora_index	= "index" -- default index filename
local testsize		= 1000 -- number of messages in the testset
local train_in_testset  = true
local in_testset        = false -- initial value
local log_prefix        = "toer-lua"
local nonspam_index     = 1 -- index to the nonspam db in the table "classes"
local spam_index        = 2 -- index to the spam db in the table "classes"

-- Experimental constants
local thick_threshold                = 20 -- overtraining protection
local header_learn_threshold         = 14 -- header overtraining protection
local reinforcement_degree           = 0.6
local ham_reinforcement_limit        = 4
local spam_reinforcement_limit       = 4
local threshold_reinforcement_degree = 1.5

-- Flags
local classify_flags            = 0
local count_classification_flag = 2
local learn_flags               = 0
local mistake_flag              = 2
local reinforcement_flag        = 4

-- dbset is the set of single class databases to be used for classification
local dbset = {
	classes     = {"nonspam.cfc", "spam.cfc"},
	ncfs        = 1, -- split "classes" in 2 sublists. "ncfs" is
	                 -- the number of classes in the first sublist.
			 -- Here, the first sublist is {"nonspam.cfc"}
			 -- and the second {"spam.cfc"}.
	delimiters  = delimiters
}
-------------------------------------------------------------------------

-- receives a file name and returns the number of lines
function count_lines(file)
  local f = assert(io.open(file, "r"))
  local _, num_lines = string.gsub(f:read("*all"), '\n', '\n')
  f:close()
  return num_lines
end

-------------------------------------------------------------------------

-- receives a single class database filename and returns
-- a string with a statistics report of the database
function dbfile_stats (dbfile)
    local OSBF_Bayes_db_version = 5 -- OSBF-Bayes database indentifier
    local report = "-- Statistics for " .. dbfile .. "\n"
    local version = "OSBF-Bayes"
    stats_lua = osbf.stats(dbfile)
    if (stats_lua.version == OSBF_Bayes_db_version) then
      report = report .. string.format(
        "%-35s%12s\n%-35s%12d\n%-35s%12.1f\n%-35s%12d\n%-35s%12d\n%-35s%12d\n",
        "Database version:", version,
        "Total buckets in database:", stats_lua.buckets,
        "Buckets used (%):", stats_lua.use * 100,
        "Trainings:", stats_lua.learnings,
        "Bucket size (bytes):", stats_lua.bucket_size,
        "Header size (bytes):", stats_lua.header_size)
      report = report .. string.format("%-35s%12d\n%-35s%12d\n%-35s%12d\n\n",
        "Number of chains:", stats_lua.chains,
        "Max chain len (buckets):", stats_lua.max_chain,
        "Average chain length (buckets):", stats_lua.avg_chain,
        "Max bucket displacement:", stats_lua.max_displacement)
    else
    	report = report .. string.format("%-35s%12s\n", "Database version:",
	    "Unknown")
    end

    return report
end

-- return the header of the message
function header(text)
  local h = string.match(text, "^(.-\n)\n")
  return h or text
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

-------------------------------------------------------------------------

corpora_dir = arg[1]

-- clean the databases
if not preserve_db then
  osbf.remove_db(dbset.classes)
  assert(osbf.create_db(dbset.classes, num_buckets))
else
  if not (file_exists(dbset.classes[1]) and
	 file_exists(dbset.classes[2])) then
    assert(osbf.create_db(dbset.classes, num_buckets))
  end
end

for i=1, 1 do

    suffix = string.format("o%d_t%d_u%g_b%d_r%d_%s_%s", threshold_offset,
		thick_threshold, header_learn_threshold, num_buckets,
		min_p_ratio, string.gsub(corpora_dir, "/", "_"), corpora_index)
    training_log = log_prefix .. "_training-log_" .. suffix
    training_stats_report = log_prefix .. "_training-stats_" .. suffix
    db_stats_report = log_prefix .. "_db-stats_" .. suffix

    if not preserve_db then
      osbf.remove_db(dbset.classes)
      assert(osbf.create_db(dbset.classes, num_buckets))
    end

    local num_msgs, hams, spams, hams_test, spams_test = 0, 0, 0, 0, 0
    local false_positives, false_negatives, trainings,
    	  reinforcements = 0, 0, 0, 0
    local false_positives_test, false_negatives_test,
    	  reinforcements_test, trainings_test = 0, 0, 0, 0
    local total_messages = count_lines(corpora_dir .. corpora_index)
    local start_of_test = total_messages - testsize + 1

    ini = os.time()

    log = assert(io.open(training_log, "w"))
    s = assert(io.open(corpora_dir .. corpora_index, "r"))
    for line in s:lines() do
      local judge, msg_name = string.match(line, "^(%S+)%s+(%S+)$")
      local file_name = corpora_dir .. msg_name
      local msg = assert(io.open(file_name, "r"))
      local text = msg:read("*all")
      msg:close()

      if max_text_size > 0 then
        text = string.sub(text, 1, max_text_size)
        text = string.match(text, "^(.*)%s%S*$")
      end
      text = text .. " " .. string.match(text, "^%s*%S+%s+%S+%s+%S+%s+%S+")
      local lim_orig_header = header(text)

      local pR, p_array, i_pmax = osbf.classify(text, dbset, classify_flags)
      if (pR == nil) then
        error(p_array)
      end

      if pR < 0 then
        class = "spam"
      else
	class = "ham"
      end

      num_msgs = num_msgs + 1
      in_testset = num_msgs >= start_of_test

      if (judge == "spam") then
	spams = spams + 1
	if in_testset then
	  spams_test = spams_test + 1
	end
	-- check classification
        if (pR >= 0) then
	  -- wrong classification, false negative
          result = "1"
	  false_negatives = false_negatives + 1
	  if not in_testset or train_in_testset then
            assert(osbf.learn(text, dbset, spam_index, learn_flags))
	    local new_pR =  osbf.classify(text, dbset, classify_flags)
  	    trainings = trainings + 1

	    if (header_learn_threshold > 0) then
              if new_pR > (threshold_offset - thick_threshold) and
                 (pR - new_pR) < header_learn_threshold then
                local i = 0
		local old_pR
                local trd = threshold_reinforcement_degree *
                            (threshold_offset - thick_threshold)
                local rd = reinforcement_degree * header_learn_threshold
                repeat
                  old_pR = new_pR
                  osbf.learn(lim_orig_header, dbset, spam_index,
				reinforcement_flag)
                  new_pR = osbf.classify(text, dbset, classify_flags)
                  i = i + 1
                until i >= spam_reinforcement_limit or
                      new_pR < trd or (old_pR - new_pR) >= rd
              end
	    end

	  end

	  if in_testset then
	    false_negatives_test = false_negatives_test + 1
	    if train_in_testset then
	      trainings_test = trainings_test + 1
	    end
	  end
        else
	  -- correctly classified as spam. check thick_threshold
	  if pR > (threshold_offset - thick_threshold) then
	    -- within unsure zone
	    if not in_testset or train_in_testset then
	      -- do reinforcement
	      assert(osbf.learn(text, dbset, spam_index, learn_flags))
	      local new_pR =  osbf.classify(text, dbset, classify_flags)

  	      result = "r"

              if new_pR > (threshold_offset - thick_threshold) and
                 (pR - new_pR) < header_learn_threshold then
                local i = 0
                local old_pR
                local trd = threshold_reinforcement_degree *
                            (threshold_offset - thick_threshold)
                local rd = reinforcement_degree * header_learn_threshold
                repeat
                  old_pR = new_pR
                  osbf.learn(lim_orig_header, dbset, spam_index,
				reinforcement_flag)
                  new_pR = osbf.classify(text, dbset, classify_flags)
                  i = i + 1
                until i >= spam_reinforcement_limit or
                      new_pR < trd or (old_pR - new_pR) >= rd
              end

	      reinforcements = reinforcements + 1
	      if in_testset then
	        reinforcements_test = reinforcements_test + 1
	      end
	    end
	  else
	    -- OK, out of unsure zone
            result = "0"
          end
        end
      else
	hams = hams + 1
	if in_testset then
	  hams_test = hams_test + 1
	end
	-- check classification
        if (pR >= 0) then
	  -- correctly classified as ham. check thick_threshold
	  if pR < (threshold_offset + thick_threshold) then
	    -- within unsure zone
	    if not in_testset or train_in_testset then
	      -- do reinforcement
	      assert(osbf.learn(text, dbset, nonspam_index, learn_flags))
	      local new_pR =  osbf.classify(text, dbset, classify_flags)

  	      result = "r"
              if new_pR < (threshold_offset + thick_threshold) and
                (new_pR - pR) < header_learn_threshold then
                local i = 0
	        local old_pR
                local trd = threshold_reinforcement_degree *
                            (threshold_offset + thick_threshold)
                local rd = reinforcement_degree * header_learn_threshold
                repeat
                  old_pR = new_pR
                  osbf.learn(lim_orig_header, dbset, nonspam_index,
				reinforcement_flag)
		  new_pR, p_array = osbf.classify(text, dbset, classify_flags)
                  i = i + 1
                 until i > ham_reinforcement_limit or
                    new_pR > trd or (new_pR - old_pR) >= rd
	      end

	      reinforcements = reinforcements + 1
	      if in_testset then
	        reinforcements_test = reinforcements_test + 1
	      end
  	    end
	  else
	    -- OK, out of unsure zone
	    result = "0"
	  end
        else
	  -- wrong classification, false positive
          result = "1"
	  false_positives = false_positives + 1
	  if not in_testset or train_in_testset then
	    assert(osbf.learn(text, dbset, nonspam_index, learn_flags))
  	    trainings = trainings + 1
	  end
	  local new_pR =  osbf.classify(text, dbset, classify_flags)

	  if in_testset then
	    false_positives_test = false_positives_test + 1
	    if train_in_testset then
	      trainings_test = trainings_test + 1
	    end
	  end

          if new_pR < (threshold_offset + thick_threshold) and
             (new_pR - pR) < header_learn_threshold then
            local i = 0
	    local old_pR
            local trd = threshold_reinforcement_degree *
                        (threshold_offset + thick_threshold)
            local rd = reinforcement_degree * header_learn_threshold
            repeat
              old_pR = new_pR
              osbf.learn(lim_orig_header, dbset, nonspam_index,
			reinforcement_flag)
              new_pR, p_array = osbf.classify(text, dbset, classify_flags)
              i = i + 1
            until i > ham_reinforcement_limit or
                  new_pR > trd or (new_pR - old_pR) >= rd
          end

        end
      end
      log:write("file=",file_name," judge=", judge, " class=", class,
	  " score=", string.format("%.4f", (0 - pR)), " user= genre= runid=none\n")
      log:flush()
    end
    s:close()
    local duration = os.time() - ini
    log:flush()
    log:close()

    -- print database stats report
    db_stats_fh = assert(io.open(db_stats_report, "w"))
    for _, dbfile in ipairs(dbset.classes) do
      db_stats_fh:write(dbfile_stats(dbfile))
    end
    db_stats_fh:close()

    -- print training stats report
    t_stats_fh = assert(io.open(training_stats_report, "w"))
    t_stats_fh:write("-- Training statistics report\n\n") 
    t_stats_fh:write("Message corpus\n") 
    t_stats_fh:write(string.format("  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n\n",
	"Hams:", hams, "Spams:", spams, "Total messages:", hams+spams))

    t_stats_fh:write("Training (OSBFBayes)\n")
    t_stats_fh:write(string.format(
      "  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n\n",
      "Thick treshold:", thick_threshold,
      "Header learn-treshold:", header_learn_threshold,
      "Trainings on error:", false_positives+false_negatives,
      "Reinforcements:", reinforcements,
      "Total learnings:", false_positives+false_negatives+reinforcements,
      "Duration (sec):", duration))

    t_stats_fh:write(
	string.format("Performance in the final %d messages (testset)\n",
			testsize))
    t_stats_fh:write(string.format(
      "  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n",
      "Hams in testset:", hams_test,
      "Spams in testset:", spams_test,
      "False positives:", false_positives_test))

   t_stats_fh:write(string.format(
     "  %-26s%7d\n  %-26s%7d\n  %-26s%7d\n  %-26s%10.2f\n  " ..
	"%-26s%10.2f\n  %-26s%10.2f\n  %-26s%10.2f\n  %-26s%10.2f\n",
     "False negatives:", false_negatives_test, 
     "Total errors in testset:", false_positives_test+false_negatives_test,
     "Reinforcements in testset:", reinforcements_test, 
     "Ham recall (%):", 100 * (hams_test - false_positives_test)/hams_test,
     "Ham precision (%):", 100 * (hams_test - false_positives_test) /
     	(hams_test - false_positives_test + false_negatives_test),
     "Spam recall (%):", 100 * (spams_test - false_negatives_test)/spams_test,
     "Spam precision (%):", 100 * (spams_test - false_negatives_test) /
     	(spams_test - false_negatives_test + false_positives_test),
     "Accuracy (%):",
      100 * (1 - (false_positives_test+false_negatives_test)/testsize)))
   t_stats_fh:close()
   -- end of report
end

