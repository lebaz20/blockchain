import js from '@eslint/js'
import globals from 'globals'
import eslintPluginUnicorn from 'eslint-plugin-unicorn'
import importPlugin from 'eslint-plugin-import'
import sonarjs from 'eslint-plugin-sonarjs'
import pluginPromise from 'eslint-plugin-promise'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['*.config.mjs']),
  {
    files: ['**/*.{js,mjs,cjs}'],
    languageOptions: {
      sourceType: 'commonjs',
      globals: {
        ...globals.nodeBuiltin,
        ...globals.node
      },
      parserOptions: {
        ecmaVersion: 2020
      }
    },
    plugins: { js, unicorn: eslintPluginUnicorn },
    extends: ['js/recommended']
  },
  importPlugin.flatConfigs.recommended,
  sonarjs.configs.recommended,
  pluginPromise.configs['flat/recommended'],
  {
    rules: {
      'sonarjs/x-powered-by': 'off',
      'sonarjs/todo-tag': 'off',
      'sonarjs/no-small-switch': 'off',
      'sonarjs/pseudo-random': 'off',
      'sonarjs/no-os-command-from-path': 'off',
      'unicorn/prevent-abbreviations': [
        'error',
        {
          allowList: { Param: true, Req: true, Res: true }
        }
      ]
    }
  }
])
