local json_codec = require("testing_runtime.json")

local H = {}

function H.new(options)
  local sequence = 0
  return {
    claim_loopback = function(request)
      sequence = sequence + 1
      local root = options.host_root .. "/listener-claims/claim-" .. tostring(sequence)
      options.run_argv({
        "node", "-e", "require('fs').mkdirSync(process.argv[1],{recursive:true})", root,
      }, options.project_root, 5)
      options.write_file(root .. "/config.json", json_codec.encode({ listeners = request.listeners }) .. "\n")
      local broker_path = options.project_root
        .. "/packages/environment-factory/tests/fixtures/listener_broker.py"
      local launch_script = table.concat({
        "const{spawn}=require('child_process');",
        "const child=spawn('python3',[process.argv[1],process.argv[2]],{detached:true,stdio:'ignore'});",
        "child.unref();process.stdout.write(String(child.pid))",
      })
      options.run_argv({ "node", "-e", launch_script, broker_path, root }, options.project_root, 5)
      local wait_script = table.concat({
        "const fs=require('fs');const root=process.argv[1];const end=Date.now()+5000;",
        "(function wait(){if(fs.existsSync(root+'/ready.json'))return process.exit(0);",
        "if(fs.existsSync(root+'/error.json'))return process.exit(49);",
        "if(Date.now()>=end)return process.exit(50);setTimeout(wait,10)})()",
      })
      options.run_argv({ "node", "-e", wait_script, root }, options.project_root, 7)
      local claim = { broker_root = root, released = false }
      claim.release = function(self)
        if self.released then return end
        self.released = true
        if #options.read_file(root .. "/response.json") > 0 then return end
        options.write_file(root .. "/release", "release\n")
        local release_wait = table.concat({
          "const fs=require('fs');const root=process.argv[1];const end=Date.now()+5000;",
          "(function wait(){if(fs.existsSync(root+'/released.json'))return process.exit(0);",
          "if(fs.existsSync(root+'/response.json'))return process.exit(0);",
          "if(Date.now()>=end)return process.exit(51);setTimeout(wait,10)})()",
        })
        options.run_argv({ "node", "-e", release_wait, root }, options.project_root, 7)
      end
      return claim
    end,
  }
end

return H
