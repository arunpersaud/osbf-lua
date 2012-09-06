#!/usr/local/bin/lua
-- read lines from stdin and list in a random order

lines = {}
count = 0
line = io.read("*line")
while (line) do
  table.insert(lines, line)
  count = count + 1
  line = io.read("*line")
end

math.randomseed(os.time())
n = count
while (n > 0) do
  i = math.random(n)
  if lines[i] then
    print(lines[i])
    table.remove(lines, i)
    n = n - 1
  end
end

