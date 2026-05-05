"use strict";

// Copyright 2025 Juspay Technologies
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import { NativeModules, Platform, TurboModuleRegistry } from 'react-native';
const LINKING_ERROR = `The package 'airborne-react-native' doesn't seem to be linked. Make sure: \n\n` + Platform.select({
  ios: "- You have run 'pod install'\n",
  default: ''
}) + '- You rebuilt the app after installing the package\n' + '- You are not using Expo Go\n';
const AirborneModule = TurboModuleRegistry && TurboModuleRegistry.get('Airborne') || NativeModules.Airborne;
const Airborne = AirborneModule ? AirborneModule : new Proxy({}, {
  get() {
    throw new Error(LINKING_ERROR);
  }
});
export function readReleaseConfig(nameSpace) {
  return Airborne.readReleaseConfig(nameSpace);
}
export function getFileContent(nameSpace, filePath) {
  return Airborne.getFileContent(nameSpace, filePath);
}
export function getBundlePath(nameSpace) {
  return Airborne.getBundlePath(nameSpace);
}
export function checkForUpdate(nameSpace) {
  return Airborne.checkForUpdate(nameSpace);
}
export function downloadUpdate(nameSpace) {
  return Airborne.downloadUpdate(nameSpace);
}
export function startBackgroundDownload(nameSpace) {
  return Airborne.startBackgroundDownload(nameSpace);
}
export function reloadApp(nameSpace) {
  return Airborne.reloadApp(nameSpace);
}
export function hasPendingBundleUpdate(nameSpace) {
  return Airborne.hasPendingBundleUpdate(nameSpace);
}
export default Airborne;
//# sourceMappingURL=index.js.map