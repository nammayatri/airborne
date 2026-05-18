declare const Airborne: any;
export declare function readReleaseConfig(nameSpace: string): Promise<string>;
export declare function getFileContent(nameSpace: string, filePath: string): Promise<string>;
export declare function getBundlePath(nameSpace: string): Promise<string>;
export declare function checkForUpdate(nameSpace: string): Promise<string>;
export declare function downloadUpdate(nameSpace: string): Promise<boolean>;
export declare function startBackgroundDownload(nameSpace: string): Promise<boolean>;
export declare function reloadApp(nameSpace: string): Promise<void>;
export declare function hasPendingBundleUpdate(nameSpace: string): Promise<boolean>;
export default Airborne;
//# sourceMappingURL=index.d.ts.map