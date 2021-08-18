local tNode = require("luasnip.nodes.textNode")
local iNode = require("luasnip.nodes.insertNode")
local fNode = require("luasnip.nodes.functionNode")
local cNode = require("luasnip.nodes.choiceNode")
local dNode = require("luasnip.nodes.dynamicNode")
local snipNode = require("luasnip.nodes.snippet")
local Environ = require("luasnip.util.environ")
local functions = require("luasnip.util.functions")
local util = require("luasnip.util.util")

local function is_escaped(text, indx)
	local count = 0
	for i = indx - 1, 1, -1 do
		if string.sub(text, i, i) == "\\" then
			count = count + 1
		else
			break
		end
	end
	return count % 2 == 1
end

local function brckt_lst(text)
	local bracket_stack = { n = 0 }
	-- will contain key-value pairs, where key and value are indices of matching
	-- brackets.
	local final_list = {}
	for i = 1, #text do
		if string.sub(text, i, i) == "{" and not is_escaped(text, i) then
			bracket_stack.n = bracket_stack.n + 1
			bracket_stack[bracket_stack.n] = i
		elseif string.sub(text, i, i) == "}" and not is_escaped(text, i) then
			final_list[bracket_stack[bracket_stack.n]] = i
			bracket_stack.n = bracket_stack.n - 1
		end
	end

	return final_list
end

local function parse_text(text)
	-- Works for now, maybe a bit naive, but gsub behaviour shouldn't change I
	-- think...
	text = string.gsub(text, "\\\\", "\\")
	text = string.gsub(text, "\\{", "{")
	text = string.gsub(text, "\\}", "}")
	text = string.gsub(text, "\\,", ",")
	text = string.gsub(text, "\\|", "|")
	text = string.gsub(text, "\\%$", "$")

	local text_table = {}
	for line in vim.gsplit(text, "\n", true) do
		text_table[#text_table + 1] = line
	end
	return tNode.T(text_table)
end

local function simple_tabstop(text, tab_stops)
	local num = tonumber(text)
	if not num then
		return nil
	end
	if not tab_stops[num] then
		tab_stops[num] = iNode.I(num)
		return tab_stops[num]
	else
		local node = fNode.F(functions.copy, { tab_stops[num] })
		tab_stops[num].dependents[#tab_stops[num].dependents + 1] = node
		return node
	end
end

local last_text = nil
local function simple_var(text)
	if Environ.is_valid_var(text) then
		local f = fNode.F(functions.var, {})
		f.user_args = { f, text }

		local indent_maybe
		if last_text ~= nil and #last_text.static_text > 1 then
			indent_maybe = last_text.static_text[#last_text.static_text]:match(
				"%s+$"
			)
		end
		if indent_maybe then
			-- remove indent-string from last_texts' text, use it to indent the
			-- variable.
			last_text.static_text[#last_text.static_text] =
				last_text.static_text[#last_text.static_text]:gsub(
					indent_maybe,
					""
				)
			-- TODO: jump into these appropriately.
			f = snipNode.PSN(nil, f, indent_maybe)
		end

		if text == "TM_SELECTED_TEXT" then
			-- Don't indent visual.
			return snipNode.ISN(nil, f, "")
		else
			return f
		end
	end
	-- if the function is unknown, just insert an empty text-snippet.
	return tNode.T({ "" })
end

-- Inserts a insert(1) before all other nodes, decreases node.pos's as indexing is "wrong".
local function modify_nodes(snip)
	for i = #snip.nodes, 1, -1 do
		snip.nodes[i + 1] = snip.nodes[i]
		local node = snip.nodes[i + 1]
		if node.pos then
			node.pos = node.pos + 1
		end
	end
	snip.nodes[1] = iNode.I(1)
end

local function brackets_offset(list, offset)
	local l_new = {}
	for k, v in pairs(list) do
		l_new[k + offset] = v + offset
	end
	return l_new
end

local parse_snippet

local function parse_placeholder(text, tab_stops, brackets)
	local start, stop, match = string.find(text, "(%d+):")
	if start == 1 then
		local pos = tonumber(match)
		local snip = parse_snippet(
			pos,
			string.sub(text, stop + 1, #text),
			tab_stops,
			brackets_offset(brackets, -stop)
		)
		local i0_maybe = nil
		if snip then
			-- SELECT Simple placeholder (static text or evaulated function that is not updated again),
			-- behaviour mopre similar to eg. vscode.
			if snip:text_only() then
				tab_stops[pos] = iNode.I(pos, string.sub(text, stop+1, -1))
			else
				if not snip:is_interactive() then
					tab_stops[pos] = dNode.D(pos, function(args)
						snip.env = args[1].env
						local iText = snip:get_static_text()
						return snipNode.SN(nil, iNode.I(1, iText))
					end, {})
				else
					-- move placeholders' indices.
					modify_nodes(snip)
					snip:init_nodes()

					tab_stops[pos] = cNode.C(pos, { snip, iNode.I(nil, { "" }) })
				end
				-- 0-node cannot be dynamic or choice, insert the actual 0-node behind it.
				if pos == 0 then
					print("le")
					-- should be high enough
					tab_stops[pos].pos = 1000
					i0_maybe = iNode.I(0)
				end
			end
			return tab_stops[pos], i0_maybe
		end
	end
	-- Parse transforms as simple copy.
	start, stop, match = string.find(text, "(%d+)/")
	if start == 1 then
		return simple_tabstop(match, tab_stops)
	end
	return nil
end

local function parse_choice(text, tab_stops)
	local start, stop, match = string.find(text, "(%d+)|")
	if start == 1 then
		local nodes = {}
		local pos = tonumber(match)
		local indx = stop + 1
		local text_start = stop + 1
		while true do
			local text_end = string.find(text, ",", indx, true)
			if text_end then
				if not is_escaped(text, text_end) then
					-- exclude ','
					nodes[#nodes + 1] = parse_text(
						string.sub(text, text_start, text_end - 1)
					)
					indx = text_end + 1
					text_start = indx
				else
					indx = text_end + 1
				end
			else
				break
			end
		end
		-- exclude final '|'
		nodes[#nodes + 1] = parse_text(string.sub(text, text_start, #text - 1))
		tab_stops[pos] = cNode.C(pos, nodes)
		return tab_stops[pos]
	end
	-- Not a choice-node.
	return nil
end

local function parse_variable(text)
	-- ignore regexes and ':' (not entirely sure what ':' is for..).
	local _, _, match = string.find(text, "([%w_]+)[:/]")
	if not match then
		_, _, match = string.find(text, "([%w_]+)$")
	end
	if match then
		-- returns empty ("") tNode if var unknown.
		return simple_var(match)
	end
	return nil
end

local function fix_node_indices(nodes)
	local highest = 0
	local used_nodes = {}
	for _, node in ipairs(nodes) do
		if node.pos then
			highest = node.pos > highest and node.pos or highest
			used_nodes[node.pos] = node
		end
	end

	for i = 1, highest do
		if not used_nodes[i] then
			for j = i+1, highest do
				if used_nodes[j] then
					used_nodes[j].pos = used_nodes[j].pos - 1
				end
			end
		end
	end
	return nodes
end

local parse_functions = {
	simple_tabstop,
	parse_placeholder,
	parse_choice,
	parse_variable,
}

parse_snippet = function(context, body, tab_stops, brackets)
	if not brackets then
		brackets = brckt_lst(body)
	end
	local outer = false
	if not tab_stops then
		tab_stops = {}
		outer = true
	end

	local nodes = {}
	local indx = 1
	local text_start = 1

	while true do
		local next_node = string.find(body, "$", indx, true)
		if next_node then
			if not is_escaped(body, next_node) then
				-- insert text so far as textNode.
				local plain_text = string.sub(body, text_start, next_node - 1)
				if plain_text ~= "" then
					last_text = parse_text(plain_text)
					nodes[#nodes + 1] = last_text
				end

				-- potentially find matching bracket.
				local match_bracket = brackets[next_node + 1]
				-- anything except text
				if match_bracket then
					-- nodestring excludes brackets.
					local nodestring = string.sub(
						body,
						next_node + 2,
						match_bracket - 1
					)
					local node1, node2
					for _, fn in ipairs(parse_functions) do
						node1, node2 = fn(
							nodestring,
							tab_stops,
							brackets_offset(brackets, -(next_node + 1))
						)
						if node1 then
							break
						end
					end
					if not node1 then
						error("Unknown Syntax: " .. nodestring)
					end
					nodes[#nodes + 1] = node1
					nodes[#nodes + 1] = node2
					indx = match_bracket + 1
					-- char after '$' is a number -> tabstop.
				elseif
					string.find(body, "%d", next_node + 1) == next_node + 1
				then
					local _, last_char, match = string.find(
						body,
						"(%d+)",
						next_node + 1
					)
					-- Add insert- or copy-function-node.
					nodes[#nodes + 1] = simple_tabstop(match, tab_stops)
					indx = last_char + 1
				elseif
					string.find(body, "%w", next_node + 1) == next_node + 1
				then
					local _, last_char, match = string.find(
						body,
						"([%w_]+)",
						next_node + 1
					)
					-- Add var-node
					nodes[#nodes + 1] = simple_var(match)
					indx = last_char + 1
				else
					error("Invalid text after $ at" .. tostring(next_node + 1))
				end
				text_start = indx
			else
				-- continues search at next node
				indx = next_node + 1
			end
		else
			-- insert text so far as textNode.
			local plain_text = string.sub(body, text_start, #body)
			if plain_text ~= "" then
				nodes[#nodes + 1] = parse_text(plain_text)
			end
			if type(context) == "number" then
				return snipNode.SN(context, fix_node_indices(nodes))
			else
				return snipNode.S(context, fix_node_indices(nodes))
			end
		end
	end
end

return {
	parse_snippet = parse_snippet,
}
