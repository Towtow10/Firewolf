
--
--  Firewolf
--  Made by GravityScore and 1lann
--

-- 1.58 Wrapper

-- Rednet

local rednet = {}

rednet.CHANNEL_BROADCAST = 65535
rednet.CHANNEL_REPEAT = 65533

local tReceivedMessages = {}
local tReceivedMessageTimeouts = {}
local tHostnames = {}

function rednet.open( sModem )
	if type( sModem ) ~= "string" then
		error( "expected string", 2 )
	end
	if peripheral.getType( sModem ) ~= "modem" then	
		error( "No such modem: "..sModem, 2 )
	end
	peripheral.call( sModem, "open", os.getComputerID() )
	peripheral.call( sModem, "open", rednet.CHANNEL_BROADCAST )
end

function rednet.close( sModem )
    if sModem then
        -- Close a specific modem
        if type( sModem ) ~= "string" then
            error( "expected string", 2 )
        end
        if peripheral.getType( sModem ) ~= "modem" then
            error( "No such modem: "..sModem, 2 )
        end
        peripheral.call( sModem, "close", os.getComputerID() )
        peripheral.call( sModem, "close", rednet.CHANNEL_BROADCAST )
    else
        -- Close all modems
        for n,sModem in ipairs( peripheral.getNames() ) do
            if rednet.isOpen( sModem ) then
                rednet.close( sModem )
            end
        end
    end
end

function rednet.isOpen( sModem )
    if sModem then
        -- Check if a specific modem is open
        if type( sModem ) ~= "string" then
            error( "expected string", 2 )
        end
        if peripheral.getType( sModem ) == "modem" then
            return peripheral.call( sModem, "isOpen", os.getComputerID() ) and peripheral.call( sModem, "isOpen", rednet.CHANNEL_BROADCAST )
        end
    else
        -- Check if any modem is open
        for n,sModem in ipairs( peripheral.getNames() ) do
            if rednet.isOpen( sModem ) then
                return true
            end
        end
    end
	return false
end

function rednet.send( nRecipient, message, sProtocol )
    -- Generate a (probably) unique message ID
    -- We could do other things to guarantee uniqueness, but we really don't need to
    -- Store it to ensure we don't get our own messages back
    local nMessageID = math.random( 1, 2147483647 )
    tReceivedMessages[ nMessageID ] = true
    tReceivedMessageTimeouts[ os.startTimer( 30 ) ] = nMessageID

    -- Create the message
    local nReplyChannel = os.getComputerID()
    local tMessage = {
        nMessageID = nMessageID,
        nRecipient = nRecipient,
        message = message,
        sProtocol = sProtocol,
    }

    if nRecipient == os.getComputerID() then
        -- Loopback to ourselves
        os.queueEvent( "rednet_message", nReplyChannel, message, sProtocol )

    else
        -- Send on all open modems, to the target and to repeaters
        local sent = false
        for n,sModem in ipairs( peripheral.getNames() ) do
            if rednet.isOpen( sModem ) then
                peripheral.call( sModem, "transmit", nRecipient, nReplyChannel, tMessage );
                peripheral.call( sModem, "transmit", rednet.CHANNEL_REPEAT, nReplyChannel, tMessage );
                sent = true
            end
        end
    end
end

function rednet.broadcast( message, sProtocol )
	rednet.send( rednet.CHANNEL_BROADCAST, message, sProtocol )
end

function rednet.receive( sProtocolFilter, nTimeout )
    -- The parameters used to be ( nTimeout ), detect this case for backwards compatibility
    if type(sProtocolFilter) == "number" and nTimeout == nil then
        sProtocolFilter, nTimeout = nil, sProtocolFilter
    end

    -- Start the timer
	local timer = nil
	local sFilter = nil
	if nTimeout then
		timer = os.startTimer( nTimeout )
		sFilter = nil
	else
		sFilter = "rednet_message"
	end

	-- Wait for events
	while true do
		local sEvent, p1, p2, p3 = os.pullEvent( sFilter )
		if sEvent == "rednet_message" then
		    -- Return the first matching rednet_message
			local nSenderID, message, sProtocol = p1, p2, p3
			if sProtocolFilter == nil or sProtocol == sProtocolFilter then
    			return nSenderID, message, sProtocol
    	    end
		elseif sEvent == "timer" then
		    -- Return nil if we timeout
		    if p1 == timer then
    			return nil
    		end
		end
	end
end

function rednet.host( sProtocol, sHostname )
    if type( sProtocol ) ~= "string" or type( sHostname ) ~= "string" then
        error( "expected string, string", 2 )
    end
    if sHostname == "localhost" then
        error( "Reserved hostname", 2 )
    end
    if tHostnames[ sProtocol ] ~= sHostname then
        if rednet.lookup( sProtocol, sHostname ) ~= nil then
            error( "Hostname in use", 2 )
        end
        tHostnames[ sProtocol ] = sHostname
    end
end

function rednet.unhost( sProtocol )
    if type( sProtocol ) ~= "string" then
        error( "expected string", 2 )
    end
    tHostnames[ sProtocol ] = nil
end

function rednet.lookup( sProtocol, sHostname )
    if type( sProtocol ) ~= "string" then
        error( "expected string", 2 )
    end

    -- Build list of host IDs
    local tResults = nil
    if sHostname == nil then
        tResults = {}
    end

    -- Check localhost first
    if tHostnames[ sProtocol ] then
        if sHostname == nil then
            table.insert( tResults, os.getComputerID() )
        elseif sHostname == "localhost" or sHostname == tHostnames[ sProtocol ] then
            return os.getComputerID()
        end
    end

    if not rednet.isOpen() then
        if tResults then
            return unpack( tResults )
        end
        return nil
    end

    -- Broadcast a lookup packet
    rednet.broadcast( {
        sType = "lookup",
        sProtocol = sProtocol,
        sHostname = sHostname,
    }, "dns" )

    -- Start a timer
    local timer = os.startTimer( 2 )

    -- Wait for events
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            -- Got a rednet message, check if it's the response to our request
            local nSenderID, tMessage, sMessageProtocol = p1, p2, p3
            if sMessageProtocol == "dns" and tMessage.sType == "lookup response" then
                if tMessage.sProtocol == sProtocol then
                    if sHostname == nil then
                        table.insert( tResults, nSenderID )
                    elseif tMessage.sHostname == sHostname then
                        return nSenderID
                    end
                end
            end
        else
            -- Got a timer event, check it's the end of our timeout
            if p1 == timer then
                break
            end
        end
    end
    if tResults then
        return unpack( tResults )
    end
    return nil
end

local bRunning = false
function rednet.run()
	if bRunning then
		error( "rednet is already running", 2 )
	end
	bRunning = true
	
	while bRunning do
		local sEvent, p1, p2, p3, p4 = os.pullEventRaw()
		if sEvent == "rednet_message" then
		    -- Got a rednet message (queued from above), respond to dns lookup
		    local nSenderID, tMessage, sProtocol = p1, p2, p3
		    if sProtocol == "dns" and tMessage.sType == "lookup" then
		        local sHostname = tHostnames[ tMessage.sProtocol ]
		        if sHostname ~= nil and (tMessage.sHostname == nil or tMessage.sHostname == sHostname) then
		            rednet.send( nSenderID, {
		                sType = "lookup response",
		                sHostname = sHostname,
		                sProtocol = tMessage.sProtocol,
		            }, "dns" )
		        end
		    end

		elseif sEvent == "timer" then
            -- Got a timer event, use it to clear the event queue
            local nTimer = p1
            local nMessage = tReceivedMessageTimeouts[ nTimer ]
            if nMessage then
                tReceivedMessageTimeouts[ nTimer ] = nil
                tReceivedMessages[ nMessage ] = nil
            end
		end
	end
end

--    Variables


local version = "3.0"
local build = 0

local w, h = term.getSize()

local serversFolder = "/fw_servers"
local indexFileName = "index"

local sides = {}

local publicDnsChannel = 9999
local publicRespChannel = 9998
local responseID = 41738

local DNSRequestTag = "--@!FIREWOLF-LIST!@--"
local DNSResponseTag = "--@!FIREWOLF-DNSRESP!@--"
local connectTag = "--@!FIREWOLF-CONNECT!@--"
local disconnectTag = "--@!FIREWOLF-DISCONNECT!@--"
local receiveTag = "--@!FIREWOLF-RECEIVE!@--"
local headTag = "--@!FIREWOLF-HEAD!@--"
local bodyTag = "--@!FIREWOLF-BODY!@--"
local initiateTag = "--@!FIREWOLF-INITIATE!@--"
local protocolTag = "--@!FIREWOLF-REDNET-PROTOCOL!@--"

local initiatePattern = "^%-%-@!FIREWOLF%-INITIATE!@%-%-(.+)"
local retrievePattern = "^%-%-@!FIREWOLF%-FETCH!@%-%-(.+)"

local theme = {
	background = colors.gray,
	accent = colors.red,
	subtle = colors.orange,

	lightText = colors.gray,
	text = colors.white,
	errorText = colors.red,
}

local default404 = [[
local function center(text)
	local x, y = term.getCursorPos()
	term.setCursorPos(math.floor(w / 2 - text:len() / 2) + (text:len() % 2 == 0 and 1 or 0), y)
	term.write(text)
	term.setCursorPos(1, y + 1)
end

term.setTextColor(colors.white)
term.setBackgroundColor(colors.gray)
term.clear()

term.setCursorPos(1, 4)
center("Error 404")
print("\n")
center("The page could not be found.")
]]



--    RC4
--    Implementation by AgentE382


local cryptWrapper = function(plaintext, salt)
	local key = type(salt) == "table" and {unpack(salt)} or {string.byte(salt, 1, #salt)}
	local S = {}
	for i = 0, 255 do
		S[i] = i
	end

	local j, keylength = 0, #key
	for i = 0, 255 do
		j = (j + S[i] + key[i % keylength + 1]) % 256
		S[i], S[j] = S[j], S[i]
	end

	local i = 0
	j = 0
	local chars, astable = type(plaintext) == "table" and {unpack(plaintext)} or {string.byte(plaintext, 1, #plaintext)}, false

	for n = 1, #chars do
		i = (i + 1) % 256
		j = (j + S[i]) % 256
		S[i], S[j] = S[j], S[i]
		chars[n] = bit.bxor(S[(S[i] + S[j]) % 256], chars[n])
		if chars[n] > 127 or chars[n] == 13 then
			astable = true
		end
	end

	return astable and chars or string.char(unpack(chars))
end


local crypt = function(plaintext, salt)
	local resp, msg = pcall(cryptWrapper, plaintext, salt)
	if resp then
		if type(msg) == "table" then
			return textutils.serialize(msg)
		else
			return msg
		end
	else
		return nil
	end
end



--    GUI


local clear = function(bg, fg)
	term.setTextColor(fg)
	term.setBackgroundColor(bg)
	term.clear()
	term.setCursorPos(1, 1)
end


local fill = function(x, y, width, height, bg)
	term.setBackgroundColor(bg)
	for i = y, y + height - 1 do
		term.setCursorPos(x, i)
		term.write(string.rep(" ", width))
	end
end


local center = function(text)
	local x, y = term.getCursorPos()
	term.setCursorPos(math.floor(w / 2 - text:len() / 2) + (text:len() % 2 == 0 and 1 or 0), y)
	term.write(text)
	term.setCursorPos(1, y + 1)
end


local title = function(text)
	fill(1, 1, w, 1, theme.accent)
	term.setCursorPos(2, 1)
	term.write(text)

	term.setCursorPos(w, 1)
	term.write("x")

	term.setBackgroundColor(theme.background)
end


local centerSplit = function(text, width)
	local words = {}
	for word in text:gmatch("[^ \t]+") do
		table.insert(words, word)
	end

	local lines = {""}
	while lines[#lines]:len() < width do
		lines[#lines] = lines[#lines] .. words[1] .. " "
		table.remove(words, 1)

		if #words == 0 then
			break
		end

		if lines[#lines]:len() + words[1]:len() >= width then
			table.insert(lines, "")
		end
	end

	for _, line in pairs(lines) do
		center(line)
	end
end



--    Server Listing Interface


local deleteServer = function(domain)
	local path = serversFolder .. "/" .. domain
	fs.delete(path)
end


local allServers = function()
	local servers = {}
	local contents = fs.list(serversFolder)

	for k, name in pairs(contents) do
		local path = serversFolder .. "/" .. name
		if fs.isDir(path) and not fs.isDir(path .. "/" .. indexFileName) then
			table.insert(servers, "rdnt://" .. name)
		end
	end

	return servers
end


local selectServer = function()
	clear(theme.background, theme.text)
	title("Select a server to host ...")

	local servers = allServers()
	table.insert(servers, 1, "New Server")

	local startY = 3
	local height = h - startY - 1
	local scroll = 0

	local draw = function()
		fill(1, startY, w, height + 1, theme.background)

		for i = scroll + 1, scroll + height do
			if servers[i] then
				term.setCursorPos(3, (i - scroll) + startY)

				if servers[i]:find("rdnt://") then
					term.setTextColor(theme.errorText)
					term.write("x ")
					term.setTextColor(theme.text)
				else
					term.write("  ")
				end

				term.write(servers[i])
			end
		end
	end

	draw()
	while true do
		local event, but, x, y = os.pullEvent()
		if event == "mouse_click" and y >= startY and y <= startY + height then
			local item = servers[y - startY + scroll]
			if item then
				item = item:gsub("rdnt://", "")
				if x == 3 then
					deleteServer(item)
					servers = allServers()
					table.insert(servers, 1, "New Server")
					draw()
				elseif x > 3 then
					if item == "New Server" then
						return nil, "new"
					else
						return item
					end
				end
			end
		elseif event == "mouse_click" and y == 1 and x == w then
			return nil
		elseif event == "key" then
			if but == keys.up then
				scroll = math.max(0, scroll - 1)
			elseif but == keys.down and #servers > height then
				scroll = math.min(scroll + 1, #servers - height)
			end
			draw()
		end
	end
end



--    Backend


local setupModem = function()
	for _, v in pairs(redstone.getSides()) do
		if peripheral.getType(v) == "modem" then
			table.insert(sides, v)
		end
	end

	if #sides <= 0 then
		error("No modem found!")
	end
end


local modem = function(func,  ...)
	for _, side in pairs(sides) do
		if peripheral.getType(side) == "modem" then
			peripheral.call(side, func,  ...)
		end
	end

	return true
end


local calculateChannel = function(domain, distance, id)
	local total = 1

	if distance then
		id = (id + 3642 * math.pi) % 100000
		if tostring(distance):find("%.") then
			local distProc = (tostring(distance):sub(1, tostring(distance):find("%.") + 1)):gsub("%.", "")
			total = tonumber(distProc..id)
		else
			total = tonumber(distance..id)
		end
	end

	for i = 1, #domain do
		total = total * string.byte(domain:sub(i, i))
		if total > 10000000000 then
			total = tonumber(tostring(total):sub(-5, -1))
		end
		while tostring(total):sub(-1, -1) == "0" do
			total = tonumber(tostring(total):sub(1, -2))
		end
	end

	return (total % 50000) + 10000
end


local isSession = function(sessions, channel, distance, id)
	for k, v in pairs(sessions) do
		if v[1] == distance and v[2] == id and v[3] == channel then
			return true
		end
	end

	return false
end


local fetchPage = function(domain, page)
	if (page:match("(.+)%.fwml$")) then
		page = page:match("(.+)%.fwml$")
	end
	local path = serversFolder .. "/" .. domain .. "/" .. page
	if fs.exists(path) and not fs.isDir(path) then
		local f = io.open(path, "r")
		local contents = f:read("*a")
		f:close()

		return contents, "lua"
	else
		if fs.exists(path..".fwml") and not fs.isDir(path..".fwml") then
			local f = io.open(path..".fwml", "r")
			local contents = f:read("*a")
			f:close()

			return contents, "fwml"
		end
	end
	return nil
end


local fetch404 = function(domain)
	local path = serversFolder .. "/" .. domain .. "/404"
	if fs.exists(path) and not fs.isDir(path) then
		local f = io.open(path, "r")
		local contents = f:read("*a")
		f:close()

		return contents
	else
		return default404
	end
end


local backend = function(serverURL, onEvent, onMessage)
	local serverChannel = calculateChannel(serverURL)
	local sessions = {}

	local receivedMessages = {}
    local receivedMessageTimeouts = {}

	modem("closeAll")
	modem("open", publicDnsChannel)
	modem("open", serverChannel)
	modem("open", rednet.CHANNEL_REPEAT)

	for _, side in pairs(sides) do
		if peripheral.getType(side) == "modem" then
			rednet.open(side)
		end
	end
	rednet.host(protocolTag .. serverURL, initiateTag .. serverURL)

	onMessage("Hosting rdnt://" .. serverURL)
	onMessage("Listening for incoming requests ...")

	while true do
		local eventArgs = {os.pullEvent()}
		local event, givenSide, givenChannel, givenID, givenMessage, givenDistance = unpack(eventArgs)
		if event == "modem_message" then
			if givenChannel == publicDnsChannel and givenMessage == DNSRequestTag and givenID == responseID then
				modem("open", publicRespChannel)
				modem("transmit", publicRespChannel, responseID, DNSResponseTag .. serverURL)
				modem("close", publicRespChannel)
			elseif givenChannel == serverChannel and givenMessage:match(initiatePattern) == serverURL then
				modem("transmit", serverChannel, responseID, crypt(connectTag .. serverURL, serverURL .. tostring(givenDistance) .. givenID))

				if #sessions > 50 then
					modem("close", sessions[#sessions][3])
					table.remove(sessions)
				end

				local isInSessions = false
				for k, v in pairs(sessions) do
					if v[1] == givenDistance and v[3] == givenID then
						isInSessions = true
					end
				end

				local userChannel = calculateChannel(serverURL, givenDistance, givenID)
				if not isInSessions then
					onMessage("[DIRECT] Starting encrypted connection: " .. userChannel)
					table.insert(sessions, {givenDistance, givenID, userChannel})
					modem("open", userChannel)
				else
					modem("open", userChannel)
				end
			elseif isSession(sessions, givenChannel, givenDistance, givenID) then
				onMessage("[DIRECT] Request from active session")

				local request = crypt(textutils.unserialize(givenMessage), serverURL .. tostring(givenDistance) .. givenID)
				if request then
					local domain = request:match(retrievePattern)
					if domain then
						local page = domain:match("^[^/]+/(.+)")
						if not page then
							page = "index"
						end

						onMessage("[DIRECT] Requested: /" .. page)

						local contents, language = fetchPage(serverURL, page)
						if not contents then
							contents = fetch404(serverURL)
						end

						local header
						if language == "fwml" then
							header = {language = "Firewolf Markup"}
						else
							header = {language = "Lua"}
						end

						modem("transmit", givenChannel, responseID, crypt(headTag .. textutils.serialize(header) .. bodyTag .. contents, serverURL .. tostring(givenDistance) .. givenID))
					elseif request == disconnectTag then
						for k, v in pairs(sessions) do
							if v[2] == givenChannel then
								sessions[k] = nil
								break
							end
						end

						modem("close", givenChannel)
						onMessage("[DIRECT] Connection closed: " .. givenChannel)
					end
				end
			elseif givenChannel == rednet.CHANNEL_REPEAT and type(givenMessage) == "table"
			and givenMessage.nMessageID and givenMessage.nRecipient and
			not receivedMessages[givenMessage.nMessageID] then
				receivedMessages[givenMessage.nMessageID] = true
				receivedMessageTimeouts[os.startTimer(30)] = givenMessage.nMessageID

				modem("transmit", rednet.CHANNEL_REPEAT, givenID, givenMessage)
				modem("transmit", givenMessage.nRecipient, givenID, givenMessage)
			end
		elseif event == "timer" then
			local messageID = receivedMessageTimeouts[givenSide]
			if messageID then
				receivedMessageTimeouts[givenSide] = nil
				receivedMessages[messageID] = nil
			end
		elseif event == "rednet_message" then
			if givenID == DNSRequestTag and givenChannel == DNSRequestTag then
				--onMessage("[REDNET] Responding to DNS request")
				rednet.send(givenSide, DNSResponseTag .. serverURL, DNSRequestTag)
			elseif givenID == protocolTag .. serverURL then
				local id = givenSide
				local decrypt = crypt(textutils.unserialize(givenChannel), serverURL .. id)
				if decrypt then
					local domain = decrypt:match(retrievePattern)
					if domain then
						local page = domain:match("^[^/]+/(.+)")
						if not page then
							page = "index"
						end

						onMessage("[REDNET] Requested: /" .. page .. " from " .. id)

						local contents, language = fetchPage(serverURL, page)
						if not contents then
							contents = fetch404(serverURL)
						end

						local header
						if language == "fwml" then
							header = {language = "Firewolf Markup"}
						else
							header = {language = "Lua"}
						end

						rednet.send(id, crypt(headTag .. textutils.serialize(header) .. bodyTag .. contents, serverURL .. givenSide), protocolTag .. serverURL)
					end
				end
			end
		end

		local shouldExit = onEvent(unpack(eventArgs))
		if shouldExit then
			rednet.unhost(protocolTag .. serverURL, initiateTag .. serverURL)
			break
		end
	end
end



--    Hosting Interface


local host = function(domain)
	clear(theme.background, theme.text)

	local onEvent = function( ...)
		local event = { ...}
		if event[1] == "mouse_click" and event[3] == w and event[4] == 1 then
			return true
		end
	end

	local onMessage = function(text)
		print("  " .. text)

		local ox, oy = term.getCursorPos()
		title("Hosting rdnt://" .. domain)
		term.setCursorPos(ox, oy)
	end

	title("Hosting rdnt://" .. domain)

	term.setCursorPos(1, 3)
	backend(domain, onEvent, onMessage)
end



--    New Server Interface


local newServer = function()
	clear(theme.background, theme.text)
	title("Create a Server")

	term.setCursorPos(3, 4)
	term.write("Domain: rdnt://")
	local domain = read()
	if domain:len() == 0 then
		return
	end

	if domain:len() < 4 then
		term.setCursorPos(3, 6)
		term.write("Domain name must be at least 4 characters!")
		sleep(2)
		return
	end

	if domain:find(" ") then
		term.setCursorPos(3, 6)
		term.write("Domain name cannot contain spaces!")
		sleep(2)
		return
	end

	local path = serversFolder .. "/" .. domain
	if not fs.exists(path) then
		fs.makeDir(path)

		local f = io.open(path .. "/index", "w")
		f:write("print(\"Hello there!\")\nprint(\"Welcome to " .. domain .. "!\")")
		f:close()
	end
end



--    Main


local main = function()
	setupModem()
	fs.makeDir(serversFolder)

	while true do
		local domain, action = selectServer()
		if not domain and not action then
			break
		end

		if action == "new" then
			newServer()
		else
			local shouldExit = host(domain)
			if shouldExit then
				break
			end
		end
	end
end


local handleError = function(err)
	clear(theme.background, theme.text)

	fill(1, 3, w, 3, theme.subtle)
	term.setCursorPos(1, 4)
	center("Firewolf Server has crashed!")

	term.setBackgroundColor(theme.background)
	term.setCursorPos(1, 8)
	centerSplit(err, w - 4)
	print("\n")
	center("Please report this error to")
	center("GravityScore or 1lann.")
	print("")
	center("Press any key to exit.")

	os.pullEvent("key")
	os.queueEvent("")
	os.pullEvent()
end


local _, err
parallel.waitForAny(function() _, err = pcall(main) end, rednet.run)

if err and not err:lower():find("terminate") then
	handleError(err)
end

if modem then
	for _, side in pairs(sides) do
		if peripheral.getType(side) == "modem" then
			rednet.close(side)
		end
	end
	modem("closeAll")
end


clear(colors.black, colors.white)
center("Thanks for using Firewolf Server " .. version)
center("Made by GravityScore and 1lann")
print("")
