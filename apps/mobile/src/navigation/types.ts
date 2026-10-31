export type SettingsSectionId =
  | 'profile'
  | 'devices'
  | 'security'
  | 'privacy'
  | 'appearance'
  | 'background'
  | 'relay'
  | 'storage'
  | 'recovery'
  | 'about';

export type RootStackParamList = {
  Onboarding: undefined;
  Inbox: undefined;
  Chat: { directId: string };
  Contacts: undefined;
  AddContact: undefined;
  Contact: { directId: string };
  Network: undefined;
  Settings: undefined;
  Section: { id: SettingsSectionId };
  Identity: undefined;
};
