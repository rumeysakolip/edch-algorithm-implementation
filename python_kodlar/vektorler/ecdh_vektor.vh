// =========================================================
// ecdh_vektor.vh — vektor_uret.py tarafindan uretildi
// ELLE DUZENLEMEYIN. Yeniden uretmek icin:
//   python3 host/vektor_uret.py --tohum 1
// =========================================================

localparam [255:0] VEK_D_A    = 256'hc9afa9d845ba75176c3937d91da02c2a1b2c3d4e5f607182a5d90c3f72a5d7f1;
localparam [255:0] VEK_QB_X   = 256'hb5e77bb791a2cc9b8871808177e017affebf67930386cecbcc687464212a4abf;
localparam [255:0] VEK_QB_Y   = 256'he4b6e8718e80e9405377d6b26942db7e109f38753ce09f6c16d2ecf9e80ab59a;
localparam [255:0] VEK_QA_X   = 256'h13faf75c66aa35163a589578fd914659e3156d852815c49aaa72eebe7ba0923f;
localparam [255:0] VEK_QA_Y   = 256'h43c06da40fe13d3005b9cfc718679bb48872c8ee44f6f56f773ee51e77ad9539;
localparam [255:0] VEK_S_X    = 256'h95c047f3b0dc5cba104efb4a3dd529948bba744cd08421ca2c3eed373760f814;
localparam [255:0] VEK_S_Y    = 256'h94c2b6bdfa5edc09f172fee5e0a7e5c29008bd32f9c58a29deb0f26e21796f14;

// Normal (Montgomery olmayan) formda — insan okunurlugu icin
// QA_X_NORM = 256'head188f3562f3e260c3f1bee8696a21e192024c05c3582e32213f1015bb1c22e
// S_X_NORM  = 256'hf4b253e1b6a66d4d2a2cafc83499bae639da72aa6c2f2017ca2ef8fcbc7949bb
