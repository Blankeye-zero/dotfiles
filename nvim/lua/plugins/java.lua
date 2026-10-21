-- ~/.config/nvim/lua/plugins/java.lua
-- Java via nvim-jdtls. jdtls is NOT started through vim.lsp.enable/mason-lspconfig
-- (it's excluded from automatic_enable in lsp.lua): nvim-jdtls starts it per project
-- root so it can pass a per-project -data workspace and the debug/test bundles.
-- jdtls, java-debug-adapter and java-test are installed by mason-tool-installer
-- (formatting.lua). Requires a JDK 21+ on PATH (or JAVA_HOME) to run jdtls itself.
return {
  {
    "mfussenegger/nvim-jdtls",
    lazy = true, -- loaded by require("jdtls") from the FileType autocmd below
    dependencies = { "mfussenegger/nvim-dap" },
    init = function()
      local mason = vim.fn.stdpath("data") .. "/mason/packages"
      local jdtls_dir = mason .. "/jdtls"

      local function java_bin()
        return vim.env.JAVA_HOME and (vim.env.JAVA_HOME .. "/bin/java") or "java"
      end

      -- Run a command in a terminal split at the bottom. Re-running the same kind
      -- (file / spring) kills the previous one first, so a Spring app doesn't keep the port.
      local run_bufs = {}
      local function run_in_term(kind, command, cwd)
        local old = run_bufs[kind]
        if old and vim.api.nvim_buf_is_valid(old) then
          vim.api.nvim_buf_delete(old, { force = true })
        end
        vim.cmd("botright 15split | enew")
        vim.fn.jobstart(command, { term = true, cwd = cwd })
        run_bufs[kind] = vim.api.nvim_get_current_buf()
        vim.cmd("normal! G") -- cursor on the last line so the window follows output
      end

      -- Launch the equinox launcher jar directly instead of Mason's `jdtls` wrapper,
      -- which is a Python script and would add a Python dependency on Windows.
      local function cmd(workspace)
        local java = java_bin()
        local config_dir = vim.fn.has("win32") == 1 and "config_win"
          or vim.fn.has("mac") == 1 and "config_mac"
          or "config_linux"
        return {
          java,
          "-Declipse.application=org.eclipse.jdt.ls.core.id1",
          "-Dosgi.bundles.defaultStartLevel=4",
          "-Declipse.product=org.eclipse.jdt.ls.core.product",
          "-Dlog.protocol=true",
          "-Dlog.level=ALL",
          "-Xmx1g",
          "--add-modules=ALL-SYSTEM",
          "--add-opens", "java.base/java.util=ALL-UNNAMED",
          "--add-opens", "java.base/java.lang=ALL-UNNAMED",
          "-javaagent:" .. jdtls_dir .. "/lombok.jar",
          "-jar", vim.fn.glob(jdtls_dir .. "/plugins/org.eclipse.equinox.launcher_*.jar"),
          "-configuration", jdtls_dir .. "/" .. config_dir,
          "-data", workspace,
        }
      end

      -- Debug + test bundles let jdtls host the DAP server (nvim-jdtls wires up nvim-dap).
      local function bundles()
        local jars = vim.split(
          vim.fn.glob(mason .. "/java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar"),
          "\n",
          { trimempty = true }
        )
        for _, jar in ipairs(vim.split(vim.fn.glob(mason .. "/java-test/extension/server/*.jar"), "\n", { trimempty = true })) do
          local name = vim.fn.fnamemodify(jar, ":t")
          -- These two aren't OSGi bundles and break jdtls if loaded.
          if name ~= "com.microsoft.java.test.runner-jar-with-dependencies.jar" and name ~= "jacocoagent.jar" then
            table.insert(jars, jar)
          end
        end
        return jars
      end

      local function attach()
        local jdtls = require("jdtls")
        -- Register the java adapter ourselves before jdtls attaches: nvim-jdtls's own
        -- setup_dap call is a no-op once the adapter exists, so only the first call's
        -- overrides apply. Program output goes to dap-ui's console instead of a terminal
        -- split (no stdin there; programs reading input need console = "integratedTerminal").
        require("jdtls.dap").setup_dap({ config_overrides = { console = "internalConsole" } })
        local root = vim.fs.root(0, { "gradlew", "mvnw", "pom.xml", "build.gradle", "build.gradle.kts", ".git" })
          or vim.fn.getcwd()
        -- One workspace per project; jdtls corrupts state if two projects share one.
        local workspace = vim.fn.stdpath("data") .. "/jdtls-workspace/"
          .. vim.fn.fnamemodify(root, ":t") .. "-" .. vim.fn.sha256(root):sub(1, 8)

        jdtls.start_or_attach({
          cmd = cmd(workspace),
          root_dir = root,
          -- start_or_attach bypasses vim.lsp.config("*"), so pass blink's capabilities explicitly.
          capabilities = require("blink.cmp").get_lsp_capabilities(),
          settings = {
            java = {
              signatureHelp = { enabled = true },
              contentProvider = { preferred = "fernflower" }, -- decompile class files on gd
              inlayHints = { parameterNames = { enabled = "all" } },
            },
          },
          init_options = { bundles = bundles() },
          on_attach = function(_, bufnr)
            -- Generic LSP keymaps come from the LspAttach autocmd in lsp.lua.
            local opts = { buffer = bufnr, silent = true }
            vim.keymap.set("n", "<leader>jo", jdtls.organize_imports, opts)
            vim.keymap.set({ "n", "v" }, "<leader>jv", jdtls.extract_variable, opts)
            vim.keymap.set({ "n", "v" }, "<leader>jc", jdtls.extract_constant, opts)
            vim.keymap.set("v", "<leader>jm", function() jdtls.extract_method(true) end, opts)
            vim.keymap.set("n", "<leader>jt", jdtls.test_nearest_method, opts)
            vim.keymap.set("n", "<leader>jT", jdtls.test_class, opts)

            -- Run the current file with Java's single-file launcher (has stdin, unlike the
            -- debugger's console). Only for self-contained files; use F5 for project code.
            vim.keymap.set("n", "<leader>jr", function()
              vim.cmd("write")
              local file = vim.api.nvim_buf_get_name(bufnr)
              run_in_term("file", { java_bin(), file }, vim.fs.dirname(file))
            end, opts)

            -- Run the Spring Boot app at the project root, preferring the project's wrapper.
            vim.keymap.set("n", "<leader>js", function()
              vim.cmd("wall")
              local win = vim.fn.has("win32") == 1
              local function has(f) return vim.uv.fs_stat(root .. "/" .. f) ~= nil end
              local command
              if has("pom.xml") then
                local mvnw = win and "mvnw.cmd" or "mvnw"
                command = { has(mvnw) and (root .. "/" .. mvnw) or "mvn", "spring-boot:run" }
              elseif has("build.gradle") or has("build.gradle.kts") then
                local gradlew = win and "gradlew.bat" or "gradlew"
                command = { has(gradlew) and (root .. "/" .. gradlew) or "gradle", "bootRun" }
              else
                vim.notify("No pom.xml or build.gradle in " .. root, vim.log.levels.WARN)
                return
              end
              run_in_term("spring", command, root)
            end, opts)
          end,
        })
      end

      -- init runs at startup, so this autocmd is the entry point; require("jdtls")
      -- in attach() is what makes lazy load the plugin.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("user_jdtls", { clear = true }),
        pattern = "java",
        callback = attach,
      })
    end,
  },
}
