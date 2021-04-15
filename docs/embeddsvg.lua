local function file_info( path )
  filename, basename, extension = path:match('(([^/]-).?([^.]+))$')

  return {
    path = string.sub(path, 0, -#filename - 1),
    filename = filename,
    basename = basename,
    extension = extension,
  }
end

local function read_file( path )
    local file = io.open( path, "rb" )
    if not file then return nil end
    local content = file:read "*a"
    file:close()
    return content
end

-- http://lua-users.org/wiki/BaseSixtyFour
local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function enc(data)
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

function Image( elem )
  local ext = file_info( elem.src ).extension 

  if ext == "svg" then
    local svg = read_file( elem.src )
    return pandoc.RawInline( "html", "<img src='data:image/svg+xml;base64," .. enc(svg) .. "'>" )
  else
    return elem
  end
end
