-- Tables in a block's output, an extra on top of its text: aligned columns
-- under a header row, as kubectl, docker, ps and df print them, `ls -l`'s
-- lines, and JSON arrays of objects. A block keeps its table as a value
-- (`block.table`), and the table stages work on it: `$3 | where STATUS =
-- Running`, `$3 | select NAME,AGE`, `$3 | sort AGE`.
--
-- Finding a table is careful, since prose must never be one: a header of
-- capitals (or a command known to print one, like df), columns that start
-- where the same blank column runs through every line, and rows with
-- something in at least two columns. When it isn't sure, it's text, and
-- the converters say what it is instead: `$3 | columns`, `from csv`,
-- `from tsv`, `from json`, `split SEP` and `lines`. Plugins read their
-- commands' output first with `parser`.
--
-- This module gathers them: reading (`table_read`), querying
-- (`table_query`), drawing (`table_draw`) and the stages (`stages`).

local read = require("./table_read")
local query = require("./table_query")
local draw = require("./table_draw")
local stages = require("./stages")

export type Table = read.Table
export type Parser = read.Parser
export type Look = draw.Look
export type Condition = query.Condition
export type Stage = stages.Stage
export type StageContext = stages.StageContext
export type StageRun = stages.StageRun
export type StageSpec = stages.StageSpec

local M = {}

M.program = read.program
M.detect = read.detect
M.columns = read.columns
M.split = read.split
M.lines = read.lines
M.csv = read.csv
M.json = read.json
M.from_value = read.from_value
M.drawn = read.drawn
M.from_json = read.from_json
M.value_text = read.value_text
M.parser = read.parser
M.matches = read.matches
M.parse = read.parse

M.all = query.all
M.durations = query.durations
M.number = query.number
M.column = query.column
M.OPS = query.OPS
M.condition = query.condition
M.matching = query.matching
M.has = query.has
M.filter = query.filter
M.sorted = query.sorted
M.where = query.where
M.select = query.select
M.sort = query.sort
M.get = query.get
M.object_tables = query.object_tables

M.look = draw.look
M.draw = draw.draw
M.text = draw.text

M.STAGES = stages.STAGES
M.pipeline = stages.pipeline
M.after_programs = stages.after_programs
M.stage = stages.stage

return M
