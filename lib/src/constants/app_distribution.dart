const isGooglePlayBuild = bool.fromEnvironment(
  'TSUMIRU_GOOGLE_PLAY',
  defaultValue: false,
);

const isServerManagerBuild = bool.fromEnvironment(
  'TSUMIRU_SERVER_MANAGER',
  defaultValue: false,
);
