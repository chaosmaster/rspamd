--[[
Copyright (c) 2016, Andrew Lewis <nerf@judo.za.org>
Copyright (c) 2016, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

local lutil = require "lua_util"
local rspamd_logger = require "rspamd_logger"
local dkim_sign_tools = require "dkim_sign_tools"
local rspamd_util = require "rspamd_util"

if confighelp then
  return
end

local settings = {
  allow_envfrom_empty = true,
  allow_hdrfrom_mismatch = false,
  allow_hdrfrom_mismatch_local = false,
  allow_hdrfrom_mismatch_sign_networks = false,
  allow_hdrfrom_multiple = false,
  allow_username_mismatch = false,
  auth_only = true,
  domain = {},
  path = string.format('%s/%s/%s', rspamd_paths['DBDIR'], 'dkim', '$domain.$selector.key'),
  sign_local = true,
  selector = 'dkim',
  symbol = 'DKIM_SIGNED',
  try_fallback = true,
  use_domain = 'header',
  use_esld = true,
  use_redis = false,
  key_prefix = 'dkim_keys', -- default hash name
}

local N = 'dkim_signing'
local redis_params
local sign_func = rspamd_plugins.dkim.sign

local function dkim_signing_cb(task)
  local ret,p = dkim_sign_tools.prepare_dkim_signing(N, task, settings)

  if not ret then
    return
  end

  if settings.use_redis then
    local function try_redis_key(selector)
      p.key = nil
      p.selector = selector
      local rk = string.format('%s.%s', p.selector, p.domain)
      local function redis_key_cb(err, data)
        if err or type(data) ~= 'string' then
          rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM key for %s: %s",
            rk, err)
        else
          p.rawkey = data
          local sret, _ = sign_func(task, p)
          if sret then
            task:insert_result(settings.symbol, 1.0)
          end
        end
      end
      local rret = rspamd_redis_make_request(task,
        redis_params, -- connect params
        rk, -- hash key
        false, -- is write
        redis_key_cb, --callback
        'HGET', -- command
        {settings.key_prefix, rk} -- arguments
      )
      if not rret then
        rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM key for %s", rk)
      end
    end
    if settings.selector_prefix then
      rspamd_logger.infox(rspamd_config, "Using selector prefix %s for domain %s", settings.selector_prefix, p.domain);
      local function redis_selector_cb(err, data)
        if err or type(data) ~= 'string' then
          rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM selector for domain %s: %s", p.domain, err)
        else
          try_redis_key(data)
        end
      end
      local rret = rspamd_redis_make_request(task,
        redis_params, -- connect params
        p.domain, -- hash key
        false, -- is write
        redis_selector_cb, --callback
        'HGET', -- command
        {settings.selector_prefix, p.domain} -- arguments
      )
      if not rret then
        rspamd_logger.infox(rspamd_config, "cannot make request to load DKIM selector for %s", p.domain)
      end
    else
      if not p.selector then
        rspamd_logger.errx(task, 'No selector specified')
        return false
      end
      try_redis_key(p.selector)
    end
  else
    if (p.key and p.selector) then
      p.key = lutil.template(p.key, {domain = p.domain, selector = p.selector})
      if not rspamd_util.file_exists(p.key) then
        rspamd_logger.debugm(N, task, 'file %s does not exists', p.key)
        return false
      end
      local sret, _ = sign_func(task, p)
      return sret
    else
      rspamd_logger.infox(task, 'key path or dkim selector unconfigured; no signing')
      return false
    end
  end
end

local opts =  rspamd_config:get_all_opt('dkim_signing')
if not opts then return end
for k,v in pairs(opts) do
  if k == 'sign_networks' then
    settings[k] = rspamd_map_add(N, k, 'radix', 'DKIM signing networks')
  elseif k == 'path_map' then
    settings[k] = rspamd_map_add(N, k, 'map', 'Paths to DKIM signing keys')
  elseif k == 'selector_map' then
    settings[k] = rspamd_map_add(N, k, 'map', 'DKIM selectors')
  else
    settings[k] = v
  end
end
if not (settings.use_redis or settings.path or settings.domain or settings.path_map or settings.selector_map) then
  rspamd_logger.infox(rspamd_config, 'mandatory parameters missing, disable dkim signing')
  lutil.disable_module(N, "config")
  return
end
if settings.use_redis then
  redis_params = rspamd_parse_redis_server('dkim_signing')

  if not redis_params then
    rspamd_logger.errx(rspamd_config, 'no servers are specified, but module is configured to load keys from redis, disable dkim signing')
    lutil.disable_module(N, "redis")
    return
  end
end


rspamd_config:register_symbol({
  name = settings['symbol'],
  callback = dkim_signing_cb
})
