-- Minimal fixture for asobi_lua_loader:new/3 PreInstall coverage.
-- probe() reads a global the host injects via PreInstall; if PreInstall
-- runs before the script is evaluated the closure captures the value,
-- otherwise it captures a stale _ENV and returns nil.
function probe()
    return injected
end
