#!/usr/local/bin/lua
-- print statistics of  a .cfc file
-- syntax: database_status.lua <cfcfile>

require "osbf"

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

-- receives a single class database filename and returns
-- a string with a statistics report of the database
function dbfile_stats (dbfile)
    local OSBF_Bayes_db_version = 5 -- OSBF-Bayes database indentifier
    local report = "-- Statistics for " .. dbfile .. "\n"
    local version = "OSBF-Bayes"
    local classifications, mistakes, error_rate;
    stats_lua, errmsg  = osbf.stats(dbfile)

    if (stats_lua and stats_lua.version == OSBF_Bayes_db_version) then

      report = report .. string.format(
        "%-35s%12s\n%-35s%12d\n%-35s%12.1f\n%-35s%12d\n%-35s%12d\n",
        "Database version:", version,
        "Total buckets in database:", stats_lua.buckets,
        "Buckets used (%):", stats_lua.use * 100,
        "Bucket size (bytes):", stats_lua.bucket_size,
        "Header size (bytes):", stats_lua.header_size)
      report = report .. string.format(
	"%-35s%12d\n%-35s%12d\n" ..
	"%-35s%12.1f\n%-35s%12d\n%-35s%12d\n%-35s%12d\n",
        "Number of chains:", stats_lua.chains,
        "Max chain len (buckets):", stats_lua.max_chain,
        "Average chain length (buckets):", stats_lua.avg_chain,
        "Max bucket displacement:", stats_lua.max_displacement,
        "Buckets unreachable:", stats_lua.unreachable,
        "Trainings:", stats_lua.learnings)

      if stats_lua.classifications then
        report = report .. string.format("%-35s%12.0f\n%-35s%12d\n%-35s%12d\n", 
          "Classifications:", stats_lua.classifications,
          "Learned mistakes:", stats_lua.mistakes,
          "Extra learnings:", stats_lua.extra_learnings)
      end
    else
    	report = report .. string.format("%-35s%12s\n", "Database version:",
	    "Unknown")
    end

    return report
end

if arg[1] and file_exists(arg[1]) then
  io.write("\n")
  io.write (dbfile_stats(arg[1]))
else
  if arg[1] then
    print("File not found: " .. arg[1])
  else
    print("Syntax: database-status.lua <db_file_name>")
  end
end

