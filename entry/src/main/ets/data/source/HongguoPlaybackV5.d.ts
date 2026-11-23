export interface PlaybackHost {
  hexDecode(value: string): Uint8Array;
  hexEncode(value: Uint8Array): string;
  utf8Encode(value: string): Uint8Array;
  base64Encode(value: Uint8Array): string;
  randomBytes(length: number): Uint8Array;
  md5(value: Uint8Array): Uint8Array;
  sm3(value: Uint8Array): Uint8Array;
}
export interface PlaybackSignedRequest {
  url: string;
  headers: Record<string, string>;
}
export interface PlaybackSigner {
  sign(base: string, values: Record<string, string>, body: Uint8Array | null, nowMs: number): PlaybackSignedRequest;
}
export function createPlaybackSigner(host: PlaybackHost): PlaybackSigner;
