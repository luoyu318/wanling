import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import globals from 'globals';

export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['src/**/*.ts'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      parserOptions: {
        projectService: true,
        tsconfigDirName: import.meta.dirname,
      },
      globals: {
        ...globals.node,
      },
    },
    rules: {
      // 审计 L8：禁用 ! 非空断言
      '@typescript-eslint/no-non-null-assertion': 'error',
      // 审计 C3：Promise 不能裸跑（需要 type info）
      '@typescript-eslint/no-floating-promises': 'error',
      // 审计 L1-L6：未使用变量
      '@typescript-eslint/no-unused-vars': ['error', {
        argsIgnorePattern: '^_',
        varsIgnorePattern: '^_',
      }],
      // 风格
      '@typescript-eslint/consistent-type-imports': 'error',
      'eqeqeq': ['error', 'always'],
      // 审计 M5：禁止 console（用 logger）
      'no-console': ['warn', { allow: ['warn', 'error'] }],
    },
  },
  {
    // 测试文件宽松（审计 L9：白盒测试 as any 是惯例；tsconfig 排除 test 故禁 typed rules）
    files: ['src/**/*.test.ts'],
    extends: [tseslint.configs.disableTypeChecked],
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-non-null-assertion': 'off',
      '@typescript-eslint/consistent-type-imports': 'off',
      'no-console': 'off',
    },
  },
  {
    ignores: ['dist/', 'node_modules/'],
  },
);
