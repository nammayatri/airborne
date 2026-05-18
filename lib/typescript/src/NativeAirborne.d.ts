import type { TurboModule } from 'react-native';
export interface Spec extends TurboModule {
    readReleaseConfig(nameSpace: string): Promise<string>;
    getFileContent(nameSpace: string, filePath: string): Promise<string>;
    getBundlePath(nameSpace: string): Promise<string>;
    checkForUpdate(nameSpace: string): Promise<string>;
    downloadUpdate(nameSpace: string): Promise<boolean>;
    startBackgroundDownload(nameSpace: string): Promise<boolean>;
    reloadApp(nameSpace: string): Promise<void>;
    hasPendingBundleUpdate(nameSpace: string): Promise<boolean>;
}
declare const _default: Spec;
export default _default;
//# sourceMappingURL=NativeAirborne.d.ts.map