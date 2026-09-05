// Pinned bytes for the quality (CTranslate2) translation models.
//
// Written by hand rather than generated, unlike TranslationModelDigests: these
// are our own conversions, published from this machine, so the digests come
// from the same pass that uploaded them rather than from probing a mirror
// nobody controls. Scripts/publish-quality-models.py prints this block.
//
// Source weights are Helsinki-NLP OPUS-MT tc-big under CC BY 4.0, converted
// with `ct2-opus-mt-converter --quantization int8` (CTranslate2 4.8.2) and
// republished at huggingface.co/beshkenadze/murmur-translation-ct2 with
// attribution.

/// SHA-256 and size of every quality model file, by direction.
enum TranslationQualityDigests {
    struct File {
        let name: String
        let sha256: String
        /// These are served uncompressed: gzip moves 248.9 MB down to only
        /// 227.0 MB on int8 weights, which are close to random, and the app
        /// would pay to inflate 249 MB for 8.8%.
        let bytes: Int
    }

    /// The files one direction needs, in the order they are fetched.
    ///
    /// A list rather than named fields because the shape genuinely varies:
    /// `en-ru` is an OPUS-MT *group* checkpoint and carries a `target_tag.txt`
    /// selecting Russian over Ukrainian or Belarusian, while `ru-en` has a
    /// single target and none. Fixed fields would force an optional that most
    /// directions leave empty.
    struct Entry {
        let files: [File]

        var totalBytes: Int { files.reduce(0) { $0 + $1.bytes } }
    }

    static let all: [String: Entry] = [
        // ru-en: opus-mt tc-big zle->eng. 60.40 chrF++ / 35.50 BLEU on
        // FLORES+ devtest, against the fast tier's 56.79 / 29.55.
        "ruen": Entry(files: [
            File(name: "model.bin",
                 sha256: "a5ad7aca8a5b7d38c312bcc10dcffdfd30b362341f7b9a2335277fc113059e23",
                 bytes: 248_860_301),
            File(name: "config.json",
                 sha256: "152eb448f1020eb55f90971d7b95f61896abee8415d555ca51ae7897ac0a0e68",
                 bytes: 221),
            File(name: "shared_vocabulary.json",
                 sha256: "b5a35f2050eba451db60ea0f740e8ebabd473f3d1b1ff4e106cd9ec134828309",
                 bytes: 2_076_466),
            File(name: "source.spm",
                 sha256: "a982dbb9362861151e36b0db1595b324cd1ce09acf46ce1f4d6d624e11c5807f",
                 bytes: 1_016_851),
            File(name: "target.spm",
                 sha256: "e69faed7f1e60eec38c64cceba35cc4fb05ec6478082f4c8a14b141fd6596e9e",
                 bytes: 802_387),
        ]),
        // en-ru: opus-mt tc-big eng->zle, a group checkpoint. The tag file is
        // load-bearing: without it the model picks a Slavic target itself,
        // which happens to be Russian often enough to look correct.
        "enru": Entry(files: [
            File(name: "model.bin",
                 sha256: "aef8701dbba8d435ff57476ccfe05ce2ebb9985543f7777514d785bdc0c7c7d7",
                 bytes: 249_438_221),
            File(name: "config.json",
                 sha256: "152eb448f1020eb55f90971d7b95f61896abee8415d555ca51ae7897ac0a0e68",
                 bytes: 221),
            File(name: "shared_vocabulary.json",
                 sha256: "f7eca39e48e45e92fb1ab9689ba7ba0c4310ae268c248db112c0dcba2f2ba32c",
                 bytes: 2_090_587),
            File(name: "source.spm",
                 sha256: "3612abfe04bf08344ba91115f0e15e228a7a15a621ea856bfd548097dbaeb43c",
                 bytes: 802_747),
            File(name: "target.spm",
                 sha256: "22940e744b3a9fd166a04880938fb61f7dfa8ba4b5d2d3f6371a6c4ba8f3b019",
                 bytes: 1_017_004),
            File(name: "target_tag.txt",
                 sha256: "a4338a293a6e68cefb04558b99536c9ffec01d4bdb17d7ad9e76f27ec4522366",
                 bytes: 8),
        ]),
    ]
}
