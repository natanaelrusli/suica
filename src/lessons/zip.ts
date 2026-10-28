import { crc32, deflateRawSync } from "node:zlib";

/**
 * A zip archive of text files, deflated, names UTF-8, every file dated `at`. Enough for a vault
 * of Markdown notes: no zip64 (so under 65,535 files and 4 GiB), no encryption, no folders entries.
 */
export function zipFiles(files: ReadonlyMap<string, string>, at: number): Buffer {
  const date = new Date(at);
  const dosTime =
    (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | (date.getUTCSeconds() >> 1);
  const dosDate =
    (Math.max(date.getUTCFullYear() - 1980, 0) << 9) |
    ((date.getUTCMonth() + 1) << 5) |
    date.getUTCDate();
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, text] of [...files].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    const raw = Buffer.from(text, "utf8");
    const packed = deflateRawSync(raw);
    const nameBytes = Buffer.from(name, "utf8");
    const crc = crc32(raw);
    const common = Buffer.alloc(26);
    common.writeUInt16LE(20, 0); // version needed
    common.writeUInt16LE(0x0800, 2); // UTF-8 names
    common.writeUInt16LE(8, 4); // deflate
    common.writeUInt16LE(dosTime, 6);
    common.writeUInt16LE(dosDate, 8);
    common.writeUInt32LE(crc, 10);
    common.writeUInt32LE(packed.length, 14);
    common.writeUInt32LE(raw.length, 18);
    common.writeUInt16LE(nameBytes.length, 22);
    // extra field length (24) stays 0
    const local = Buffer.concat([Buffer.from("PK\x03\x04", "latin1"), common, nameBytes, packed]);
    const central = Buffer.alloc(46);
    central.write("PK\x01\x02", 0, "latin1");
    central.writeUInt16LE(20, 4); // version made by
    common.copy(central, 6); // version needed … name length, extra length
    // comment length, disk, internal and external attributes stay 0
    central.writeUInt32LE(offset, 42);
    locals.push(local);
    centrals.push(Buffer.concat([central, nameBytes]));
    offset += local.length;
  }
  const directory = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.write("PK\x05\x06", 0, "latin1");
  end.writeUInt16LE(files.size, 8);
  end.writeUInt16LE(files.size, 10);
  end.writeUInt32LE(directory.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, directory, end]);
}
