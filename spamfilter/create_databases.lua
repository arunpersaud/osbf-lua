#!/usr/local/bin/lua
-- Script for creating the databases

local osbf = require("osbf")

-- database classes to be created
dbset = { classes = {"nonspam.cfc", "spam.cfc"} }

-- number of buckets in each database
if arg[1] then
  num_buckets = tonumber(arg[1])
else
  num_buckets = 94321
end

if num_buckets == nil then
  print("Error: argument must be a number")
  os.exit(1)
end

-- remove old databases
-- osbf.remove_db(dbset.classes)

-- create new, empty databases
r, err = osbf.create_db(dbset.classes, num_buckets)
if not r then print(err) end

