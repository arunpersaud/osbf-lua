#!/usr/local/bin/lua
-- This script calculates 1-ROCAC%, a measure of the quality of the classifier.
-- The lower the value the better the filter. See "A Study of Supervised
-- Spam Detection applied to Eight Months of Personal E-Mail", by Gordon
-- Cormack and Thomas Lynam, for a more detailed explanation:
--   http://plg.uwaterloo.ca/~gvcormac/spamcormack.040621.pdf

-- Note: In that study, the score is a measure of the "spaminess" while the
-- OSBF-Lua score is a measure of the "haminess", i. e. non negative values
-- are indicative of ham, while negative values are indicative of spam.
-- This script handles both log formats, TREC and TOER.

-- This script is based on the algorithm 2 presented in "ROC Graphs: Notes
-- and Practical Considerations for Researchers", by Tom Fawcett:
--   http://www.hpl.hp.com/techreports/2003/HPL-2003-4.pdf

-- Usage ex.: roc.lua toer-lua_training-log_t20_u3_b94321_r1_shuffle01

-- Fidelis Assis - 11/2005

-- do we have a log file?
if (not arg[1]) then
 print("Syntax: roc.lua <toer-lua_training-log>")
 return 1
end

local MAX_DBL = 1E307
local MIN_DBL = 1E-307

-- print x,y points?
local opt_v = false

function sort_scores_trec(a, b)
        return (tonumber(string.match(b, "score=(%S+)")) <
                tonumber(string.match(a, "score=(%S+)"))
               )
end

function sort_scores_toer(a, b)
        return (-tonumber(string.match(b, ";([^;]+);")) <
	        -tonumber(string.match(a, ";([^;]+);"))
	       )
end

local sort_scores
local spam_regex, spam_regex, signal

local lines = {}
for line in io.lines(arg[1]) do
  table.insert(lines, line)
end

if string.match(lines[1], "file=%S+ judge=%S+ class=.+ score=") then
  spam_regex = "judge=spam"
  score_regex = " score=(%S+)"
  signal = 1
  sort_scores = sort_scores_trec
else
  spam_regex = "^[^;]*[Ss][Pp][Aa][Mm]"
  score_regex = ".-;([^;]+);"
  signal = -1
  sort_scores = sort_scores_toer
end

-- count number of positive (spam) and negative (ham) examples
local P, N = 0, 0
for i = 1, #lines, 1 do
  if string.match(lines[i], spam_regex) then
    P = P + 1
  else
    N = N + 1
  end
end

table.sort(lines, sort_scores)

-- Generate curve points and calculate AAC (Area Above the Curve)
local prev = -MAX_DBL;

local area, tp, fp = 0, 0, 0
local prev_x, prev_y = 0, 0
local x, y, lx, ly

for i = 1, #lines, 1 do
  local score = string.match(lines[i], score_regex)
  score = signal * tonumber(score)
  if prev ~= score then
    if N > 0 then
      x = fp/N
    else
      x = 1
    end
    if P > 0 then
      y = tp/P
    else
      y = 1
    end
    
    if x == 1.0 then
      lx = MAX_DBL
    elseif x == 0 then
      lx = -MAX_DBL
    else
      lx = math.log10(x / (1.0 - x))
    end

    if y == 1.0 then
      ly = MAX_DBL
    elseif y == 0 then
      ly = -MAX_DBL
    else
      ly = math.log10(y / (1.0 - y))
    end

    area = area + (x - prev_x) * (y + prev_y)/2.0
    prev_x = x
    prev_y = y

    if (lx >= -MAX_DBL and lx <= MAX_DBL and
        ly >= -MAX_DBL and ly <= MAX_DBL) then
      if opt_v then
        io.write(lx, " ", ly, "\n")
      end
    end
  end
  prev = score
  if string.match(lines[i], spam_regex) then
    tp = tp + 1
  else
    fp = fp + 1
  end
end

area = area + (1 - prev_x) * (1 + prev_y)/2
io.write(string.format("1-ROCA%%: %0.6f\n", 100 * (1 - area)))

