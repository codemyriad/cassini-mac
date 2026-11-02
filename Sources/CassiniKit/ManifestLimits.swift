// SPDX-License-Identifier: GPL-3.0-or-later

/// The largest session.json any Cassini reader accepts. The supported worst case
/// is 64 tracks with 1000 D52.2 gap ranges and an overflow marker each, 999 events
/// and every source row: about 11 MB pretty-printed. A tighter bound sends valid
/// recordings into recovery and loses their offsets, events and source identities.
public enum SessionManifestLimit {
    public static let bytes = 16 << 20
}

/// The largest meeting.json any Cassini writer produces or reader accepts. D52.2
/// mirrors every gap range into `recordingDetails.captureRecord`, so the record for
/// the session worst case must fit beside the app's own metadata.
public enum MeetingMetadataLimit {
    public static let bytes = 16 << 20
}
