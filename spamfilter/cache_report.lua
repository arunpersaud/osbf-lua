#!/usr/local/bin/lua
-- Script for sending training form email to the user
-- Version 1.0.2
--
-- This software is licensed to the public under the Free Software
-- Foundation's GNU GPL, version 2.  You may obtain a copy of the
-- GPL by visiting the Free Software Foundations web site at
-- www.fsf.org, and a copy is included in this distribution.
--
-- Copyright 2006, 2007  Fidelis Assis, all rights reserved.

--[[
 Syntax: cache_report.lua [--cfgdir=<user_config_dir>]
			  [--dbdir=<user_db_dir>]  
			  [--cachedir=<user_db_dir>]  
			  [--train_addr=<email>]  
			  <user_osbf-lua_dir>
			  <user_email>

 <user_osbf-lua_dir> is the directory where the user config file,
 databases, log and cache dirs are located.
 
 <user_email> is the email address the training form is sent to.

 --cfgdir, --dbdir and --cachedir may be used for specifying the path for
 config file, database and cache directories, if they are not the same as
 <user_osbf-lua_dir>.

 --train_addr specifies the training address, that is, the address the
 training command will be sent to, when the user clicks the "Send Actions"
 button in the form. If not specified, the training address is the same as
 <user_email>. 

 Sends an email with an HTML training form containing the cached sfids
 starting with "sfid--" and "sfid-+", limited to max_sfids (default 50).
 If there are less than max_sfids in that range, more are added from
 those with with score within [-20, +20]. The total sfids sent are
 limited to sfids.

 Each row of the table in the training form contains Date, From,
 Subject and a drop down menu with the possible actions: Train as spam,
 Train as non-spam, Recover message from cache, Add 'From:' to whitelist
 and Remove from cache.

 The actions are pre-selected according to what the spamfilter thinks
 of the message and the text in the rows are colored red for spam or blue
 for nonspam, for quick decision. The user can change the pre-selected
 actions, but in most cases he has just to click "Send Actions".

 This training mechanism requires that the email client supports HTML
 messages with "mailto" form action. It works fine with Mozilla
 Thunderbird and Microsoft Outlook. It was not tested with other email
 clients. This script is tipically launched from a cron job.

--]]

local osbf = require "osbf"

local gOsbf_path = string.match(arg[0], "^(.*/)")
if not gOsbf_path then
  gOsbf_path = "./"
end
-- set path for require
package.path = gOsbf_path .. "?.lua;" .. package.path

require "getopt"

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

gOptind, gOptions = getopt(arg, {cfgdir = 1, dbdir = 1, logdir = 1,
				 cachedir = 1, train_addr = 1})

if type(gOptions) ~= "table" then
  if type(gOptions) == "string" then
    io.stderr:write("Error:", gOptions, "\n")
  else
    io.stderr:write("Error while reading command line options\n")
  end
  return 1
end

if gOptind then
  gUser_osbf_dir = arg[gOptind]
  gEmail =  arg[gOptind+1]
end

if not gUser_osbf_dir or not gEmail then
  io.stderr:write([[

 Syntax: cache_report.lua [--cfgdir=<user_config_dir>]
 			  [--dbdir=<user_db_dir>]  
			  [--cachedir=<user_cache_dir>]  
			  [--logdir=<user_log_dir>]  
			  [--train_addr=<email>]  
			  <user_osbf-lua_dir>
			  <user_email>

 Read the text at the top of the script for details.

]])
  return 1
end

gUser_osbf_dir = append_slash(gUser_osbf_dir)
gTrain_addr    = gOptions["train_addr"] or gEmail
gConfig_dir    = append_slash(gOptions["cfgdir"])   or gUser_osbf_dir
gDatabase_dir  = append_slash(gOptions["dbdir"])    or gUser_osbf_dir
gCache_dir     = append_slash(gOptions["cachedir"]) or gUser_osbf_dir
gLog_dir       = append_slash(gOptions["logdir"])   or gUser_osbf_dir

local max_sfids    = 50

local cache_dir = gCache_dir .. "cache/"
local log_dir   = gLog_dir .. "log/"


-- English
---[[
local msg_subject = "OSBF-Lua training form"
local msg_send_actions = "Send Actions"
local msg_title = 
	"<a href=3Dhttp://osbf-lua.luaforge.net>OSBF-Lua</a> " ..
	"Training Form<br>Check the pre-selected " ..
	"actions, change if necessary, and click &quot;" .. 
	msg_send_actions .. "&quot;"
local msg_title_nready  =
	"<a href=3Dhttp://osbf-lua.luaforge.net>OSBF-Lua</a> " ..
	"Training Form<br> Select the proper training action for each " ..
	"message and click &quot;" .. msg_send_actions .. "&quot;"
local msg_none 		= "None"
local msg_recover	= "Recover message"
local msg_remove	= "Remove from cache"
local msg_whitelist_from = "Add 'From:' to whitelist"
local msg_whitelist_subj = "Add 'Subject:' to whitelist"
local msg_train_as_ham	= "Train as Non-spam"
local msg_train_as_spam = "Train as Spam"
local msg_train_undo    = "Undo training"
local msg_train_nomsgs  = "No messages for training"
local msg_table_date	= "Date"
local msg_table_from 	= "From"
local msg_table_subject	= "Subject"
local msg_table_action 	= "Action"

local msg_stats_stats 	  = "Statistics"
local msg_stats_num_class = "Classifications"
local msg_stats_mistakes  = "Mistakes"
local msg_stats_trainings = "Trainings"
local msg_stats_accuracy  = "Accuracy"
local msg_stats_spam 	  = "Spam"
local msg_stats_non_spam  = "Non Spam"
local msg_stats_total     = "Total"
--]]

-- Brazilian Portuguese
--[[
local msg_subject = "OSBF-Lua - =?ISO-8859-1?Q?formul=E1rio_de_treinamento?="
local msg_send_actions = "Enviar A&ccedil;&otilde;es"
local msg_title		= 
  "<a href=3Dhttp://osbf-lua.luaforge.net>OSBF-Lua</a> - Formul&aacute;rio " ..
  "de treinamento<br>Verifique as a&ccedil&otilde;es pr&eacute;-" ..
  "selecionadas, altere se necess&aacute;rio, e clique em &quot;" .. 
  msg_send_actions .. "&quot;"
local msg_title_nready  =
  "<a href=3Dhttp://osbf-lua.luaforge.net>OSBF-Lua</a> - Formul&aacute;rio " ..
  "de treinamento<br>Selecione a a&ccedil;&atilde;o de treinamento " ..
  " adequada para cada mensagem e clique em &quot;" ..  msg_send_actions ..
  "&quot;"
local msg_none 		= "Nenhuma"
local msg_recover	= "Recuperar mensagem"
local msg_remove	= "Remover do cache"
local msg_whitelist_from = "P&ocirc;r remetente em whitelist"
local msg_whitelist_subj = "P&ocirc;r 'Assunto:' em whitelist"
local msg_train_as_ham	= "Treinar como N&atilde;o-Spam"
local msg_train_as_spam = "Treinar como Spam"
local msg_train_undo    = "Desfazer treinamento"
local msg_train_nomsgs  = "N&atilde;o h&aacute; mensagens para treinamento"
local msg_table_date	= "Data"
local msg_table_from 	= "De"
local msg_table_subject	= "Assunto"
local msg_table_action 	= "A&ccedil;&atilde;o"

local msg_stats_stats 	  = "Estat&iacute;sticas"
local msg_stats_num_class = "Classifica&ccedil;&otilde;es"
local msg_stats_mistakes  = "Erros"
local msg_stats_trainings = "Treinamentos"
local msg_stats_accuracy  = "Precis&atilde;o"
local msg_stats_spam 	  = "Spam"
local msg_stats_non_spam  = "N&atilde;o Spam"
local msg_stats_total     = "Total"
--]]


function log(txt)
      local h = io.open(log_dir .. "log_cache.txt", "a")
      h:write(txt, "\n")
      h:close()
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

if not my_dofile(gConfig_dir .. "spamfilter_config.lua") then
  io.stderr:write("Couldn't read config file: " .. gConfig_dir ..
		 "spamfilter_config.lua\n")
  return 1
end

local mail_cmd = osbf.cfg_mail_cmd or "/usr/lib/sendmail -it <"

-- for case insensitive match - from PIL
function nocase (s)
  s = string.gsub(s, "%a", function (c)
        return string.format("[%s%s]", string.lower(c),
                                       string.upper(c))
      end)
  return s
end

function make_select(sfid, ready)
  local select = [[
<select class=3D"menu" onChange=3D"this.style.backgroundColor=3D'#ffec8b'"
 name=3D]] ..  sfid
  if ready and string.match(sfid, "sfid%-[-S]") then
    select = select .. [[>
    <option class=3D"menu" value=3D"none">]] .. msg_none .. [[
    <option class=3D"menu" value=3D"recover">]] .. msg_recover .. [[
    <option class=3D"menu" value=3D"remove">]] .. msg_remove .. [[
    <option class=3D"menu" value=3D"whitelist_from">]] .. msg_whitelist_from .. [[
    <option class=3D"menu" value=3D"whitelist_subject">]] .. msg_whitelist_subj .. [[
    <option class=3D"menu" value=3D"spam" selected>]] .. msg_train_as_spam .. [[
    <option class=3D"menu" value=3D"nonspam">]] .. msg_train_as_ham .. [[
    <option class=3D"menu" value=3D"undo">]] .. msg_train_undo 
  elseif ready and string.match(sfid, "sfid%-[+H]") then
    select = select .. [[>
    <option class=3D"menu" value=3D"none">]] .. msg_none .. [[
    <option class=3D"menu" value=3D"recover">]] .. msg_recover .. [[
    <option class=3D"menu" value=3D"remove">]] .. msg_remove .. [[
    <option class=3D"menu" value=3D"whitelist_from">]] .. msg_whitelist_from .. [[
    <option class=3D"menu" value=3D"whitelist_subject">]] .. msg_whitelist_subj .. [[
    <option class=3D"menu" value=3D"spam">]] .. msg_train_as_spam .. [[
    <option class=3D"menu" value=3D"nonspam" selected>]] .. msg_train_as_ham  .. [[
    <option class=3D"menu" value=3D"undo">]] .. msg_train_undo 
  else
    select = select .. [[>
    <option class=3D"menu" value=3D"none" selected>]] .. msg_none .. [[
    <option class=3D"menu" value=3D"recover">]] .. msg_recover .. [[
    <option class=3D"menu" value=3D"remove">]] .. msg_remove .. [[
    <option class=3D"menu" value=3D"whitelist_from">]] .. msg_whitelist_from .. [[
    <option class=3D"menu" value=3D"whitelist_subject">]] .. msg_whitelist_subj .. [[
    <option class=3D"menu" value=3D"spam">]] .. msg_train_as_spam .. [[
    <option class=3D"menu" value=3D"nonspam">]] .. msg_train_as_ham  .. [[
    <option class=3D"menu" value=3D"undo">]] .. msg_train_undo 
  end

  select = select .. "</option></select></td></tr>=\n"
  return select
end

function limit_lines(text, len)
  local limited_text = ""
  if len < 5 then len = 5 end
  if string.sub(text, -1) ~= "\n" then
    text = text .. "\n"
  end
  local ilen = len - 3 -- reserve space for final =20 or final "=\n"
  for l in string.gmatch(text, "(.-\n)") do
    local ll = string.len(l)
    if ll > ilen then
      --local first = string.sub(l, 1, ilen)
      local first = string.match(string.sub(l, 1, ilen), "^(.+[^=][^=])")
      ilen = string.len(first)
      if string.sub(first, -1) == " " then
        limited_text = limited_text ..
          string.sub(first, 1, ilen-1) .. "=20\n" ..
          limit_lines(string.sub(l, ilen+1), len)
      else
        limited_text = limited_text ..
          first .. "=\n" ..
          limit_lines(string.sub(l, ilen+1), len)
      end
    else
      l = string.gsub(l, " \n", "=20\n")
      l = string.gsub(l, "\t\n", "=09\n")
      limited_text =  limited_text .. l
    end
  end
  return limited_text
end

-- send a message using a tmp file. os.popen may not be available
function send_message(message)
  local tmpfile = string.match(os.tmpname(), "([^/]+)$")
  local i = 0
  local f
  while i < 10 do
    f = io.open(log_dir .. tmpfile, "r")
    if f then
      print(tmpfile)
      f:close()
      tmpfile = string.match(os.tmpname(), "([^/]+)$")
      i = i + 1
    else
      break
    end
  end
  if i < 10 then
    local tmp = io.open(log_dir .. tmpfile, "w")
    if tmp then
      tmp:write(message)
      tmp:close()
      os.execute(mail_cmd .. log_dir .. tmpfile)
      os.remove(log_dir .. tmpfile)
    end
  end
end

-- return an array table with classes statistics
function get_stats(classes)
    local version = "OSBF-Bayes"
    local error_rate1, error_rate2, global_error_rate, spam_rate

    return {osbf.stats(classes[1], false), osbf.stats(classes[2], false)}
end

-- return an HTML table with statistics
function stats_html_table(stats, ready)

    if (stats[1].version == 5 and stats[2].version == 5) then

      if stats[1].classifications and stats[2].classifications then
        if stats[1].classifications + stats[1].mistakes - stats[2].mistakes > 0
	then
          error_rate1 = stats[1].mistakes /
           (stats[1].classifications + stats[1].mistakes - stats[2].mistakes)
        else
          error_rate1 = 0
        end
      end

      if stats[1].classifications and stats[2].classifications then
        if stats[2].classifications + stats[2].mistakes - stats[1].mistakes > 0 then
          error_rate2 = stats[2].mistakes /
           (stats[2].classifications + stats[2].mistakes - stats[1].mistakes)
        else
          error_rate2 = 0
        end
      end


      if stats[1].classifications + stats[2].classifications > 0 then
        spam_rate = (stats[2].classifications+stats[2].mistakes-stats[1].mistakes)/
             (stats[1].classifications+stats[2].classifications)
      else
        spam_rate = 0
      end

      if stats[1].classifications + stats[2].classifications > 0 then
        global_error_rate = (stats[1].mistakes + stats[2].mistakes) /
         (stats[1].classifications + stats[2].classifications)
      else
        global_error_rate = 0
      end

      local f = [[
<center>
<table always=3D"" border=3D"1" bordercolor=3D"#3d0000" cellpadding=3D"4" cellspacing=3D"0">
  <col width=3D"136"> <col width=3D"109"> <col width=3D"75"><col width=3D"111"> <col width=3D"92">
  <tbody>
    <tr class=3D"stats_header" height=3D"25" valign=3D"middle">
      <td width=3D"136">
      <p><i><b>]] .. msg_stats_stats .. [[</b></i></p> </td>
      <td width=3D"109">
      <p align=3D"center"><b>]] .. msg_stats_num_class .. [[</b></p></td>
      <td width=3D"75">
      <p align=3D"center"><b>]] .. msg_stats_mistakes .. [[</b></p></td>
      <td width=3D"111">
      <p align=3D"center"><b>]] .. msg_stats_trainings .. [[</b></p></td>
      <td width=3D"92">
      <p align=3D"center"><b>]] .. msg_stats_accuracy .. [[</b></p></td>
    </tr>
    <tr class=3D"stats_row" valing=3D"MIDDLE" height=3D"25">
      <td width=3D"136" align="left">
      <p><b>]] .. msg_stats_non_spam .. [[</b></p></td>
      <td width=3D"109"> <p>%d</p></td>
      <td width=3D"75"> <p>%s</p></td>
      <td width=3D"111"> <p>%d</p></td>
      <td width=3D"92"> <p>%s</p></td>
    </tr>
    <tr class=3D"stats_row" valing=3D"MIDDLE" height=3D"25">
      <td width=3D"136" align="left">
      <p><b>]] .. msg_stats_spam .. [[</b></p> </td>
      <td width=3D"109"> <p>%d</p></td>
      <td width=3D"75"> <p>%s</p></td>
      <td width=3D"111"> <p>%d</p></td>
      <td width=3D"92"> <p>%s</p></td>
    </tr>
    <tr class=3D"stats_footer" valing=3D"MIDDLE" height=3D"25">
      <td width=3D"136" align="left">
      <p><b>]] .. msg_stats_total .. [[</b></p></td>
      <td width=3D"109"> <p>%d</p></td>
      <td width=3D"75"> <p>%s</p></td>
      <td width=3D"111"> <p>%d</p></td>
      <td width=3D"92"> <p>%s</p></td>
    </tr>
  </tbody>
</table>
</center>
]]
     return(string.format(f,
	stats[2].classifications,
	ready and string.format("%d", stats[2].mistakes) or "-",
	stats[2].learnings,
	ready and string.format("%.2f%%", (1 - error_rate2) * 100) or "-",

	stats[1].classifications,
	ready and  string.format("%d", stats[1].mistakes) or "-",
	stats[1].learnings,
	ready and string.format("%.2f%%", (1 - error_rate1) * 100) or "-",

	stats[1].classifications+stats[2].classifications,
	ready and  string.format("%d",
				stats[1].mistakes+stats[2].mistakes) or "-",
	stats[1].learnings+stats[2].learnings,
	ready and string.format("%.2f%%",
				 (1 - global_error_rate) * 100) or "-"
	))
  end
end

rfc2822_to_localtime = (
function ()
  tmonth = {jan=1, feb=2, mar=3, apr=4, may=5, jun=6,
            jul=7, aug=8, sep=9, oct=10, nov=11, dec=12}

  return function (date)

    -- remove comments (CFWS)
    date = string.gsub(date, "%b()", "")

    -- Ex: Tue, 21 Nov 2006 14:26:58 -0200
    local day, month, year, hh, mm, ss, zz =
      string.match(date,
       "%a%a%a,%s+(%d+)%s+(%a%a%a)%s+(%d%d+)%s+(%d%d):(%d%d)(%S*)%s+(%S+)")

    if not (day and month and year) then
      day, month, year, hh, mm, ss, zz =
      string.match(date,
       "(%d+)%s+(%a%a%a)%s+(%d%d+)%s+(%d%d):(%d%d)(%S*)%s+(%S+)")
      if  not (day and month and year) then
        return nil
      end
    end

    local month_number = tmonth[string.lower(month)]
    if not month_number then
      return nil
    end

    year = tonumber(year)

    if year >= 0 and year < 50 then
      year = year + 2000
    elseif year >= 50 and year <= 99 then
      year = year + 1900
    end

    if not ss or ss == "" then
      ss = 0
    else
      ss = string.match(ss, "^:(%d%d)$")
    end

    if not ss then
      return nil
    end


    local tz = nil
    local s, zzh, zzm = string.match(zz, "([-+])(%d%d)(%d%d)")
    if s and zzh and zzm then
      tz = zzh * 3600 + zzm * 60
      if s == "-" then tz = -tz end
    else
      if zz == "GMT" or zz == "UT" then
        tz = 0;
      elseif zz == "EST" or zz == "CDT" then
        tz = -5 * 3600
      elseif zz == "CST" or zz == "MDT" then
        tz = -6 * 3600
      elseif zz == "MST" or zz == "PDT" then
        tz = -7 * 3600
      elseif zz == "PST" then
        tz = -8 * 3600
      elseif zz == "EDT" then
        tz = -4 * 3600
      -- todo: military zones
      end
    end

    if not tz then
      return nil
    end
 
    local ts = os.time{year=year, month=month_number,
                        day=day, hour=hh, min=mm, sec=ss}

    if not ts then
--[[
      local h = io.open(log_dir .. "log_cache.txt", "a")
      h:write(date, "\n")
      h:close()
--]]
      return nil
    end

    -- find out the local offset to UTC
    local uy, um, ud, uhh, umm, uss =
         string.match(os.date("!%Y%m%d %H:%M:%S", ts),
                         "(%d%d%d%d)(%d%d)(%d%d) (%d%d):(%d%d):(%d%d)")
    lts = os.time{year=uy, month=um,
                        day=ud, hour=uhh, min=umm, sec=uss}
    local off_utc = ts - lts

    return ts - (tz - off_utc)
  end
end)()

function get_header(msg)
  if msg then
    local header = string.match(msg, "^(.-\n)\n") or msg
    if string.sub(header, -1) ~= "\n" then
      header = header .. "\n"
    end
    return header
  else
    return nil
  end
end

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

--------------------------------------------------------

local gStats = get_stats{gDatabase_dir .. "spam.cfc",
			gDatabase_dir .. "nonspam.cfc"}

local ready = gStats[1].learnings >= 10 and gStats[2].learnings >= 10

if not ready then msg_title = msg_title_nready end

local gMain_header = "From: " .. gEmail ..  "\nTo: " .. gEmail .. 
	"\nX-Spamfilter-Lua-Whitelist: " .. osbf.cfg_pwd .. 
[[

Subject: ]] .. msg_subject .. [[

MIME-Version: 1.0
Content-Type: multipart/mixed;
	boundary="--=-=-=-train-report-boundary-=-=-="
This is a multi-part message in MIME format.

----=-=-=-train-report-boundary-=-=-=
Content-Type: text/html
Content-Transfer-Encoding: quoted-printable

]]

local start_html = [[
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"><html>
<head><meta content=3D"text/html; charset=3DISO-8859-1" http-equiv=3D"
content-type"><title>Train_form</title>

<style>
select.menu, option.menu {
  font-family: Helvetica, sans-serif;
  font-size: 11px;
}

tr.msgs {
  font-family: Helvetica, sans-serif;
  font-size: 14px;
  height: 24px;
  background-color: #ddeedd;
}

tr.stats_header {
  font-family: Helvetica, sans-serif;
  font-size: 12px;
  color: rgb(0, 0, 0);
  background-color: rgb(172, 172, 124);
}
tr.stats_row {
  font-family: Helvetica, sans-serif;
  font-size: 12px;
  color: rgb(0, 0, 0);
  background-color: rgb(221, 238, 221);
  text-align: right;
}
tr.stats_footer {
  font-family: Helvetica, sans-serif;
  font-size: 12px;
  color: rgb(0, 0, 0);
  background-color: rgb(201, 216, 201);
  text-align: right;
}

</style>

</head><body>]]

local start_form = [[
<div style=3D"text-align: left;"><small><span style=3D"font-weight: bold;
font-family: Helvetica, sans-serif;"><i>]] .. msg_title .. 
[[</i></span></small><br></div><form enctype=3D"text/plain" method=3D"post" 
action=3D"mailto:]] .. gTrain_addr .. "?subject=3Dbatch_train " .. 
osbf.cfg_pwd .. [[" 
name=3D"TRAIN_FROM"><div style=3D"text-align: center;"></div>
<table style=3D"text-align: left; max-width: 80%; height: 48px;" border
=3D"0" cellpadding=3D"2" cellspacing=3D"2"><tbody><tr>
<th style=3D"text-align: center; max-width: 18%; font-family: Helvetica, sans-serif;
 background-color: #acac7c; height: 24px;"> <p><small><span 
 style=3D"font-weight: bold;">]] .. msg_table_date .. 
[[</span></small></p> </th>
<th style=3D"text-align: center; max-width: 23%; font-family: Helvetica, sans-serif;
 background-color: #acac7c; height: 24px;"><p><small><span
 style=3D"font-weight: bold;">]] .. msg_table_from ..
[[</span></small></p></th> <th
 style=3D"max-width: 45%; text-align: center; font-family: Helvetica, sans-serif;
 background-color: #acac7c; height: 24px;"><p><small><span
 style=3D"font-weight: bold;">]] .. msg_table_subject ..
[[</span></small></p></th><th
 style=3D"text-align: center; max-width: 14%; font-family: Helvetica, sans-serif;
 background-color: #acac7c; height: 24px;"><p><small><span style
=3D"font-weight: bold;">]] .. msg_table_action ..
[[</span></small></p></th></tr>
]]

local end_form = [[
</tbody></table><br>]] .. [[<div style=3D"text-align: center;">
<input accesskey=3D"E" type=3D"submit" value=3D"]] .. msg_send_actions ..
[["></form><br><hr><br>]]

local end_html = stats_html_table(gStats, ready) ..
[[</div></body></html>

----=-=-=-train-report-boundary-=-=-=--
]]

local lines, lines_out = 0, 0
local sfidtab, sfidtab_out = {}, {}

local sfid_subdirs = {""}
if osbf.cfg_use_sfid_subdir then
  sfid_subdirs = {os.date("%d/%H/", os.time()- 24*3600), -- yesterday
		  os.date("%d/%H/", os.time())}          -- today
end

for _, subdir in ipairs(sfid_subdirs) do
  for f in osbf.dir(cache_dir .. subdir) do
    if string.match(f, "sfid%-[-+].+[^-][^sh]$") then
      lines = lines + 1
      sfidtab[lines] = f
      if lines >= max_sfids then
        break
      end
    elseif string.match(f,
	"sfid%-[^BW]-[-+]0[01].[%.,]..%-%d-@.+[^-][^sh]$") then
      lines_out = lines_out + 1
      sfidtab_out[lines_out] = f
    end
  end
end

for _, f in ipairs(sfidtab_out) do
  if lines < max_sfids then
    lines = lines + 1
    sfidtab[lines] = f
  else
    break
  end
end

local from, subject, date, loop_msg, header
local sfid_subdir, gText, h, cache_filename

loop_msg = ""
for _, f in ipairs(sfidtab) do
  sfid_subdir = get_sfid_subdir(f)
  cache_filename = cache_dir .. sfid_subdir .. f
  gText = nil
  h = io.open(cache_filename, "r")
  if h then
    gText = h:read("*all")
    h:close()
  end
  if gText and gText ~= "" then
    header = "\n" .. get_header(gText) or gText
    from    = string.match(header, nocase("\nFrom") .. "%s-:%s-(.-)\n")
    subject = string.match(header, nocase("\nSubject") .. "%s-:%s-(.-)\n")
    date    = string.match(header, nocase("\nDate") .. "%s-:%s-(.-)\n")

    if not subject then
      subject = "(no subject)"
    end
    if not from then
      from = "(no from)"
    end
    if not date then
      date = "(no date)"
    end

    from = string.gsub(from, nocase("=%?ISO%-8859%-1%?Q%?") .. "(.-)%?=", "%1")
    from = string.gsub(from, "(" .. string.rep("%S", 32) ..")(%S)", "%1 %2")
    from = string.gsub(from, '&', '&amp;')
    from = string.gsub(from, '"', '&quot;')
    from = string.gsub(from, '<', '&lt;')
    from = string.gsub(from, '>', '&gt;')

    subject = string.gsub(subject,
		nocase("=%?ISO%-8859%-1%?Q%?") .. "(.-)%?=", "%1")
    subject = string.gsub(subject,
		"(" .. string.rep("%S", 40) ..")(%S)", "%1 %2")
    subject = string.gsub(subject, '&', '&amp;')
    subject = string.gsub(subject, '"', '&quot;')
    subject = string.gsub(subject, '<', '&lt;')
    subject = string.gsub(subject, '>', '&gt;')

    if ready and string.match(f, "sfid%-[-S]") then
      fgcolor = "#ff0000"
    elseif ready and string.match(f, "sfid%-[+H]") then
      fgcolor = "#0000aa"
    else
      fgcolor = "#000000"
    end

    local  date_fgcolor = fgcolor
    local lts = rfc2822_to_localtime(date) 
    if lts then
      date = os.date("%Y/%m/%d %H:%M", lts)
    else
      -- if date not valid, paint it red
      date_fgcolor = "#ff0000"
    end

    loop_msg = loop_msg ..  [[
<tr class=3D"msgs">
 <td style=3D"width: 15%; max-width: 18%; color: ]] .. date_fgcolor ..
 [[;"><small>]] .. date .. [[</small></td>
 <td style=3D"width: 26%; max-width: 23%; color: ]] .. fgcolor ..
 [[;"><small>]] .. from .. [[</small></td>
 <td style=3D"width: 45%; max-width: 45%; color: ]] .. fgcolor ..
 [[;"><small>]] .. subject .. [[</small></td>
 <td style=3D"width: 14%; max-width: 14%; vertical-align: middle; color: ]] ..
 fgcolor .. [[;"><p><small> ]] .. make_select(f, ready)
  else
    io.stderr:write("Erro ao abrir " .. cache_filename .. "\n")
  end
end

if lines > 0 then
  send_message(gMain_header .. 
		limit_lines(start_html .. start_form .. loop_msg ..
		end_form .. end_html, 65))
else
  send_message(gMain_header .. 
		limit_lines(start_html .. 
		"<center>" .. msg_train_nomsgs .. "</center><p>" ..
		end_html, 65))

end

--[[ Yes, this code is a mess. ]]--

