-- ~/.config/nvim/lua/plugins/dap.lua
return {
    {
        "mfussenegger/nvim-dap",
        dependencies = {
            "rcarriga/nvim-dap-ui",
            "nvim-neotest/nvim-nio",
            "theHamsta/nvim-dap-virtual-text",
        },
        config = function()
            local dap = require("dap")
            local dapui = require("dapui")

            dapui.setup()
            -- Inline variable values next to the code while stopped.
            require("nvim-dap-virtual-text").setup({ virt_text_pos = "eol" })

            -- Default signs are bare letters ("B", "->"); use icons and highlight the stopped line.
            vim.api.nvim_set_hl(0, "DapStoppedLine", { default = true, link = "Visual" })
            local signs = {
                DapBreakpoint = { "●", "DiagnosticError" },
                DapBreakpointCondition = { "◆", "DiagnosticWarn" },
                DapLogPoint = { "◉", "DiagnosticInfo" },
                DapBreakpointRejected = { "○", "DiagnosticHint" },
                DapStopped = { "▶", "DiagnosticOk", "DapStoppedLine" },
            }
            for name, sign in pairs(signs) do
                vim.fn.sign_define(name, { text = sign[1], texthl = sign[2], linehl = sign[3], numhl = "" })
            end

            -- lldb-dap ships with the LLVM install (Mason's clangd install) and
            -- speaks DAP natively, so no separate debug adapter (e.g. codelldb) is needed.
            dap.adapters.lldb = {
                type = "executable",
                command = "C:/Program Files/LLVM/bin/lldb-dap.exe",
                name = "lldb",
            }

            -- Generic fallback for any C++ project that doesn't define its own override -
            -- prompts for the executable path each time. Projects that want a fixed,
            -- no-prompt target should set dap.configurations.cpp themselves in a project-local
            -- .nvim.lua (auto-sourced via 'exrc', see init.lua) rather than editing this file.
            dap.configurations.cpp = {
                {
                    name = "Launch",
                    type = "lldb",
                    request = "launch",
                    program = function()
                        return vim.fn.input("Path to executable: ", vim.fn.getcwd() .. "/build/", "file")
                    end,
                    cwd = function()
                        return vim.fn.getcwd() .. "/build"
                    end,
                    stopOnEntry = false,
                    args = {},
                },
            }
            dap.configurations.c = dap.configurations.cpp

            -- Auto open/close the UI (breakpoints, scopes, variables, stacks) with the session.
            -- Applies to every language's DAP session (cpp, go, ...), not just cpp.
            dap.listeners.after.event_initialized["dapui_config"] = function()
                dapui.open()
            end
            dap.listeners.before.event_terminated["dapui_config"] = function()
                dapui.close()
            end
            dap.listeners.before.event_exited["dapui_config"] = function()
                dapui.close()
            end

            local opts = { silent = true }
            vim.keymap.set("n", "<leader>db", dap.toggle_breakpoint, opts)
            vim.keymap.set("n", "<leader>dc", dap.continue, opts)
            vim.keymap.set("n", "<leader>di", dap.step_into, opts)
            vim.keymap.set("n", "<leader>do", dap.step_over, opts)
            vim.keymap.set("n", "<leader>dO", dap.step_out, opts)
            vim.keymap.set("n", "<leader>dr", dap.repl.open, opts)
            vim.keymap.set("n", "<leader>du", dapui.toggle, opts)
            vim.keymap.set("n", "<leader>dq", dap.terminate, opts)
            vim.keymap.set("n", "<leader>dB", function()
                dap.set_breakpoint(vim.fn.input("Condition: "))
            end, opts)
            vim.keymap.set("n", "<leader>dl", function()
                dap.set_breakpoint(nil, nil, vim.fn.input("Log message: "))
            end, opts)
            vim.keymap.set("n", "<leader>dC", dap.run_to_cursor, opts)
            vim.keymap.set("n", "<leader>dL", dap.run_last, opts)
            vim.keymap.set("n", "<leader>dR", dap.restart, opts)
            -- Evaluate the expression under the cursor (or the visual selection) in a float.
            vim.keymap.set({ "n", "v" }, "<leader>de", dapui.eval, opts)

            -- IDE-style function keys for the step loop (F11 is fullscreen in Windows Terminal,
            -- so step into also lives on Shift-F11 / <leader>di).
            vim.keymap.set("n", "<F5>", dap.continue, opts)
            vim.keymap.set("n", "<F9>", dap.toggle_breakpoint, opts)
            vim.keymap.set("n", "<F10>", dap.step_over, opts)
            vim.keymap.set("n", "<F11>", dap.step_into, opts)
            vim.keymap.set("n", "<S-F11>", dap.step_out, opts)
            vim.keymap.set("n", "<F12>", dap.step_out, opts)
        end,
    },

    -- Installs the delve debug adapter binary through Mason, the same way
    -- mason-lspconfig's ensure_installed does for LSP servers.
    {
        "jay-babu/mason-nvim-dap.nvim",
        dependencies = { "mason-org/mason.nvim", "mfussenegger/nvim-dap" },
        opts = {
            ensure_installed = { "delve" },
            automatic_installation = true,
        },
    },

    -- Go: adapter/configs (Debug, Debug test, Debug test (go.mod), Attach) via delve on $PATH
    -- (Mason puts its bin dir on $PATH for Neovim, so the mason-installed `dlv` is found automatically).
    {
        "leoluz/nvim-dap-go",
        ft = "go",
        dependencies = { "mfussenegger/nvim-dap" },
        opts = {},
    },
}
