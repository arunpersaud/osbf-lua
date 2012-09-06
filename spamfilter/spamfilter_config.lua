-- command password
osbf.cfg_pwd = "your_password_here" -- no spaces allowed

-- database files
osbf.cfg_nonspam_file = "nonspam.cfc"
osbf.cfg_spam_file    = "spam.cfc"

osbf.cfg_min_pR_success    = 0  -- min pR to be considered as nonspam
osbf.cfg_threshold         = 10 -- low score range, or reinforcement zone,
				-- around osbf.cfg_min_pR_success. Use 20
				-- during the pre-training phase for better
				-- accuracy and reduce to 10 or less later,
				-- for less burden with daily trainings.

-- tags for the subject line
osbf.cfg_tag_subject     = true
osbf.cfg_tag_spam        = "[--]"  -- tag for spam messages
osbf.cfg_tag_unsure_spam = "[-]"   -- tag for low abs score spam messages
osbf.cfg_tag_unsure_ham  = "[+]"   -- tag for low score ham messages
osbf.cfg_tag_ham         = ""      -- tag for ham messages

-- training result subjects
osbf.cfg_trained_as_spam        = "Trained as spam"
osbf.cfg_trained_as_nonspam     = "Trained as nonspam"
osbf.cfg_training_not_necessary = "Training not necessary: score = %.2f; " ..
				  "out of learning region: [-%.1f, %.1f]"

-- Use SFID unless explicitely told otherwise. Uncomment to disable sfids.
--osbf.cfg_dont_use_sfid     = true

-- SFID rightid - change it to personalize for your site.
osbf.cfg_rightid        = "spamfilter.osbf.lua"

-- Where to insert the SFID? Uncomment only one of them:
--osbf.cfg_insert_sfid_in  = "references"
--osbf.cfg_insert_sfid_in  = "message-id"
osbf.cfg_insert_sfid_in  = "both"

-- log options
osbf.cfg_save_for_training = true  -- save msg for later training
osbf.cfg_log_incoming      = true  -- log all incoming messages
osbf.cfg_log_learned       = true  -- log learned messages
osbf.cfg_log_dir           = "log" -- relative to the user osbf-lua dir

-- If osbf.cfg_use_sfid_subdir is true, messages cached for later training
-- are saved under a subdir under osbf.cfg_log_dir, formed by the day of
-- the month and the time the message arrived (DD/HH), to avoid excessive
-- files per dir. The subdirs must be created before you enable this option.
--osbf.cfg_use_sfid_subdir   = true

-- Count classifications? Comment or set to false to turn off
osbf.cfg_count_classifications = true

-- This option specifies that the original message will be written to stdout
-- after a training, with the correct tag. To have the original behavior,
-- that is, just a report message, comment this option out.
osbf.cfg_output       = "message"

-- Turn on to use Lua-regex in white and black lists. Check the whitelist
-- command in the help message before turning this on.
osbf.cfg_lists_use_regex = false
 
-- Set osbf.cfg_remove_body_threshold to the score below which you want the
-- message body removed. Use this option after you have well trained
-- databases:
--osbf.cfg_remove_body_threshold = -2 * osbf.cfg_threshold

-- Command to send pre-formatted command messages.
-- The command must accept one arg, the file containing the pre-formatted
-- message to be sent.
osbf.cfg_mail_cmd = "/usr/lib/sendmail -it < "

