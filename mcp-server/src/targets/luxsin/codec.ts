/**
 * Luxsin X8 wire codec — ported verbatim from the Luxsin Controller bundle
 * (app-C8qvm0eX.js, symbols Z9/Ehe). The device exchanges JSON encoded with a
 * custom-alphabet base64: standard base64 with the character set permuted.
 *
 * Validated by:
 *   - JS round-trip self-test (unicode + emoji), 4/4 pass
 *   - live device read: GET /dev/info.cgi?action=syncPeq decodes to valid JSON
 *
 * Source alphabets (do not change — they are the device's, not ours):
 *   Q9 (scrambled) = "KLMPQRSTUVWXYZABCGHdefIJjkNOlmnopqrstuvwxyzabcghiDEF34501289+67/"
 *   J9 (standard)  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
 */

const Q9 = "KLMPQRSTUVWXYZABCGHdefIJjkNOlmnopqrstuvwxyzabcghiDEF34501289+67/";
const J9 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/**
 * Decode a device response (Z9). scrambled-base64 → standard base64 (Q9→J9
 * char substitution) → atob → UTF-8 string.
 */
export function luxsinDecode(input: string): string {
  let standard = "";
  for (let i = 0; i < input.length; i++) {
    const ch = input.charAt(i);
    const r = Q9.indexOf(ch);
    standard += r !== -1 ? J9.charAt(r) : ch;
  }
  const binary = atob(standard);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder("utf-8").decode(bytes);
}

/**
 * Encode a request body (Ehe). UTF-8 string → byte string → standard base64
 * (btoa) → scrambled base64 (J9→Q9 char substitution).
 */
export function luxsinEncode(input: string): string {
  const byteString = encodeURIComponent(input).replace(
    /%([0-9A-F]{2})/g,
    (_m, hex: string) => String.fromCharCode(parseInt(hex, 16)),
  );
  return btoa(byteString)
    .split("")
    .map((ch) => {
      const o = J9.indexOf(ch);
      return o !== -1 ? Q9[o] : ch;
    })
    .join("");
}
