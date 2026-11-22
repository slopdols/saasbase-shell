const { defineConfig } = require('@vue/cli-service')

module.exports = defineConfig({
  transpileDependencies: true,
  devServer: {
    port: 8080
  },
  css: {
    loaderOptions: {}
  },
  chainWebpack: (config) => {
    // vue-i18n v9 defaults to the legacy message compiler (compileToFunction),
    // which calls `new Function` at runtime and violates the strict CSP in
    // vercel.json (script-src 'self', no 'unsafe-eval').
    // Enable JIT compilation so messages are compiled to AST and interpreted
    // without eval/new Function. See: https://vue-i18n.intlify.dev/guide/advanced/optimization.html#jit-compilation
    config.plugin('define').tap((args) => {
      args[0]['__INTLIFY_JIT_COMPILATION__'] = JSON.stringify(true)
      return args
    })
  }
})
