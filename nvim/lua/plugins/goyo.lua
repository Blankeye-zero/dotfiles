return {
    {
        "junegunn/goyo.vim",
        cmd = "Goyo",
        dependencies = { "junegunn/limelight.vim" },
        keys = {
            { "<leader>z", "<cmd>Goyo<cr>", desc = "Toggle Goyo" },
        },
        config = function()
            vim.api.nvim_create_autocmd("User", {
                pattern = "GoyoEnter",
                command = "Limelight",
            })
            vim.api.nvim_create_autocmd("User", {
                pattern = "GoyoLeave",
                command = "Limelight!",
            })
        end,
    },
}
