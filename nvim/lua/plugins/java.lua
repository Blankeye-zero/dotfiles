-- ~/.config/nvim/lua/plugins/java.lua
-- Java via nvim-jdtls. jdtls is NOT started through vim.lsp.enable/mason-lspconfig
-- (it's excluded from automatic_enable in lsp.lua): nvim-jdtls starts it per project
-- root so it can pass a per-project -data workspace and the debug/test bundles.
-- jdtls, java-debug-adapter and java-test are installed by mason-tool-installer
-- (formatting.lua). Requires a JDK 21+ on PATH (or JAVA_HOME) to run jdtls itself.
return {
  {
    "mfussenegger/nvim-jdtls",
    ft = "java",
    dependencies = { "mfussenegger/nvim-dap" },
    config = function()
      local mason = vim.fn.stdpath("data") .. "/mason/packages"
      local jdtls_dir = mason .. "/jdtls"

      -- Launch the equinox launcher jar directly instead of Mason's `jdtls` wrapper,
      -- which is a Python script and would add a Python dependency on Windows.
      local function cmd(workspace)
        local java = vim.env.JAVA_HOME and (vim.env.JAVA_HOME .. "/bin/java") or "java"
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
          end,
        })
      end

      -- lazy re-fires FileType after loading on ft=java, so this also covers the first buffer.
      vim.api.nvim_create_autocmd("FileType", { pattern = "java", callback = attach })
    end,
  },
}
