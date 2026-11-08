/** @type {import('jest').Config} */
module.exports = {
  testEnvironment: 'node',
  modulePathIgnorePatterns: [
    '<rootDir>/apps/server/build/',
    '<rootDir>/apps/server/dist/',
  ],
  testMatch: [
    '<rootDir>/packages/**/*.test.ts',
    '<rootDir>/contracts/**/*.test.ts',
    '<rootDir>/apps/mobile/src/**/*.test.ts',
    '<rootDir>/apps/mobile/src/**/*.test.tsx',
  ],
  transform: {
    '^.+\\.[tj]sx?$': 'babel-jest',
  },
  transformIgnorePatterns: [
    '/node_modules/(?!.*(@noble|@scure|sql\\.js))',
  ],
  moduleNameMapper: {
    '^@direct/shared$': '<rootDir>/packages/shared/src/index.ts',
    '^@direct/crypto$': '<rootDir>/packages/crypto/src/index.ts',
    '^@direct/protocol$': '<rootDir>/packages/protocol/src/index.ts',
    '^@direct/transport$': '<rootDir>/packages/transport/src/index.ts',
    '^react-native$': 'react-native-web',
    '\\.(css)$': '<rootDir>/apps/mobile/src/test/styleMock.cjs',
  },
  setupFiles: ['<rootDir>/apps/mobile/src/test/jest.setup.cjs'],
};
