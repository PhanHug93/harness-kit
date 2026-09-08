## Request (verbatim)

> Có một finding mới cần bạn xem xét và gộp báo cáo để tiến hành luôn:
> Hãy sửa lỗi đọc model profile trong harness-kit, bao gồm template sinh helper và các bản mirror tương ứng. Giữ nguyên thay đổi khác; không commit/push hoặc chạy setup trên project thật.
> Nguyên nhân đã tái hiện trên ESPL Android: load_model_profile gọi Python với 2>&1, gộp stderr vào stdout chứa TSV. Python trên macOS sandbox có thể phát cảnh báo: `python3: warning: confstr() failed with code 5: couldn't get path of DARWIN_USER_TEMP_DIR; using /tmp instead`. Python vẫn exit 0 và xuất đúng TSV, nhưng Bash `IFS=$'\t' read -r -a fields <<< "$parsed"` chỉ đọc dòng cảnh báo đầu tiên → `model profile error: parser returned 1 fields; expected 11`.
> Yêu cầu sửa: (1) tách stdout dữ liệu khỏi stderr chẩn đoán ngay khi chạy Python; (2) thành công: chỉ parse stdout, giữ cảnh báo trên stderr; (3) thất bại: trả lỗi, giữ chẩn đoán gốc, không khởi chạy Codex; (4) file tạm bằng mktemp, dọn cả hai đường, trap phạm vi subshell; (5) tương thích Bash 3.2; (6) không chữa bằng bỏ dòng đầu/cuối, lọc chữ "warning", tắt stderr hoặc đổi model/effort.
> Test bắt buộc: profile hợp lệ không cảnh báo; hợp lệ + cảnh báo exit 0; Python khởi động thất bại; JSON sai + cảnh báo; reasoning_effort sai + cảnh báo; ca lỗi không gọi Codex, không rò rỉ file tạm. RED trước sửa, GREEN sau sửa; chèn lại 2>&1 phải làm ca cảnh báo thất bại.
> Chạy syntax từng script, doctor/status, verifier, catalog check, onboarding và full bootstrap kit theo quy ước repo. Dùng Codex giả để kiểm tra launch; báo rõ các bước chưa chạy.
> Lưu ý từ ESPL: full kit dừng tại `operator README Astra authorization limitation missing` — README ESPL vẫn ghi `Sol authorization entries are audit declarations`. Kiểm tra harness-kit có cùng vấn đề không; nếu có, đồng bộ tài liệu đúng phạm vi, không nới assertion chỉ để lấy PASS.

(Phần cấu hình ESPL — planning/reviewing = gpt-6-astra @ ultra, coding = gpt-5.6-luna @ xhigh, fallback = gpt-5.6-terra, audit token `policy_exception=sol_coding` — là cấu hình của target ESPL, xem mục "Phạm vi harness-kit vs ESPL".)

## Objective

Trong helper sinh ra `.codex/codex-mode.sh` (nguồn duy nhất: heredoc quoted tại
`agent-bootstrap/lib/writers-docs.sh:1814`, hàm `load_model_profile` :1918),
tách stdout TSV của Python khỏi stderr chẩn đoán để một cảnh báo Python exit 0
không làm `status`/`doctor`/mọi launch thất bại; giữ nguyên hành vi lỗi
(không launch Codex khi profile lỗi) và toàn bộ model/effort mặc định.

## Đã tái hiện trên harness-kit (Claude, target sinh từ worktree)

Với wrapper `python3` in đúng dòng cảnh báo confstr ra stderr rồi exec python3 thật:
`status` → `ERROR: model profile error: parser returned 1 fields; expected 8`;
`doctor` → `FAIL model profile error: parser returned 1 fields; expected 8`;
`planning "hello"` (fake codex) → cùng lỗi, Codex không được gọi. Harness-kit
expect **8** trường (ESPL là 11 vì helper của ESPL là bản fork có thêm trường).
Chi tiết: `evidence/claude-prototype-results.md`.

Mức độ: P1 với route Codex — cảnh báo này xuất hiện trong shell sandbox trên
macOS (chính là môi trường Claude Code gọi `/codex:status`, `/codex:setup`),
và fail-closed cả ba route dù profile hợp lệ.

## Phạm vi harness-kit vs ESPL

- harness-kit chỉ có **một** bản helper (heredoc writers-docs.sh). Không có
  mirror nào khác chứa `load_model_profile` (đã grep toàn repo). Không có
  test nào che ca này (không có `assert_codex_profile_stderr_isolation`).
- Model/effort mặc định của harness-kit giữ nguyên: sol/luna/terra @ xhigh;
  `allowed_efforts` giữ nguyên (`ultra` vẫn bị từ chối — đúng, xem case 5).
  Cấu hình astra/ultra và 11 trường là fork cục bộ của ESPL; packet này
  **không** đưa vào harness-kit. Follow-up riêng (ngoài packet): làm
  per-mode effort và danh sách effort thành dữ liệu trong `model-profiles.json`
  + schema để ESPL không cần fork helper (fork sẽ bị candidate ghi đè khi
  upgrade).
- Wording README: harness-kit nhất quán — `README.md:157`,
  `agent-bootstrap/README.md:77` và assertion test :1739 đều là
  `Sol authorization entries are audit declarations`. **Không có vấn đề
  Astra ở harness-kit.** Lỗi ESPL là do đợt đổi tên Sol→Astra chỉ sửa
  assertion mà chưa sửa README của ESPL: ESPL cần sửa README (docs) cho khớp
  tên mới, không nới assertion. Không thay đổi gì ở harness-kit cho mục này.

## Acceptance criteria

AC1. Profile hợp lệ, Python không cảnh báo: `status`, `doctor`, launch (fake
codex) hoạt động như hiện tại; stderr không có thêm dòng nào.
AC2. Profile hợp lệ, Python in cảnh báo ra stderr và exit 0: `status` rc 0 và
in đúng profile/model; `doctor` báo `ok model profile stable ...`; launch gọi
fake codex với đúng `--model` và `model_reasoning_effort`; **dòng cảnh báo
được giữ nguyên trên stderr** (không bị nuốt, không bị lọc).
AC3. Python khởi động thất bại (wrapper in chẩn đoán ra stderr, exit ≠ 0):
`MODEL_PROFILE_ERROR` = chẩn đoán gốc; `status`/launch rc 1; fake codex không
được gọi.
AC4. JSON sai định dạng + cảnh báo: rc 1, lỗi chứa nguyên văn
`model profile error: malformed JSON ...` (cảnh báo có thể đứng trước), không launch.
AC5. `reasoning_effort` không hợp lệ + cảnh báo: rc 1, lỗi chứa
`unsupported reasoning_effort`, không launch.
AC6. Mọi ca (thành công lẫn lỗi) không để lại file tạm: test đặt `TMPDIR` vào
thư mục mới và assert rỗng sau mỗi ca; TMPDIR không ghi được → lỗi rõ
`cannot create a temporary file under ...`, rc 1, không launch.
AC7. Trap chỉ tồn tại trong subshell của command substitution; trap EXIT của
caller (nếu có) không bị ghi đè — test: bọc lời gọi trong shell có
`trap 'echo CALLER_TRAP' EXIT` và assert marker vẫn in ra.
AC8. Không dùng: bỏ dòng đầu/cuối, `grep -v warning`, `2>/dev/null`, đổi
model/effort. Kiểm chứng bằng review diff.
AC9. Binding: chèn lại `2>&1` vào dòng gọi Python trong helper sinh ra →
ca AC2 đỏ với đúng thông điệp `parser returned 1 fields; expected 8`.
Ghi RED (trước sửa) và GREEN (sau sửa) vào `implementation.md` kèm log.
AC10. Bash 3.2: chạy `/bin/bash -n .codex/codex-mode.sh` và
`/bin/bash .codex/codex-mode.sh status|doctor` trên macOS (`/bin/bash --version`
ghi 3.2.57) với target sinh mới — bắt buộc vì container/VM Linux không có 3.2.
AC11. Suite: `bash -n` từng script sửa; shellcheck với exclusions của CI
không thêm cảnh báo; `sync-template-catalog.sh --check`; `verify-ai-deps.sh`
trên target sinh; `test-onboarding-fixtures.sh`, `test-one-shot-upgrade.sh`,
`test-bootstrap-multi-agent-project.sh` đều rc 0.

## Thiết kế tham khảo (đã prototype và chạy qua 6 ca + reinsertion)

Patch: `evidence/reference-writers-docs.patch` (apply sạch lên writers-docs.sh
hiện tại của worktree; số dòng tính sau thay đổi của packet guard). Ý chính:

- Toàn bộ việc gọi Python nằm trong **một** `$( ... )`; bên trong:
  `mktemp "${TMPDIR:-/tmp}/codex-mode-profile.XXXXXX"` (template hợp lệ cả
  macOS/GNU), `trap 'rm -f "$profile_stderr"' EXIT` — trap thuộc subshell
  của command substitution nên không chạm trap của caller.
- Python chạy với `2>"$profile_stderr"`; stdout đi thẳng vào giá trị
  `parsed`. Thành công: `cat "$profile_stderr" >&2` (giữ cảnh báo), `exit 0`.
  Thất bại: in nội dung stderr ra stdout để thành `MODEL_PROFILE_ERROR`
  (giữ chẩn đoán gốc); nếu stderr rỗng thì
  `python3 exited with status N without diagnostics`; `exit 1`.
- Giữ nguyên kiểm tra `expected 8` phía sau như lưới an toàn; giữ nguyên
  toàn bộ chương trình Python và `allowed_efforts`.
- Chỉ dùng cấu trúc có trong Bash 3.2: `$( )`, heredoc quoted, `trap EXIT`,
  `[[ -s ]]`, `printf`, `read -r -a`. Không `mapfile`, không `|&`,
  không `${var@Q}`, không `local -n`.

## Tests — `scripts/test-bootstrap-multi-agent-project.sh`

Thêm hàm `assert_codex_profile_stderr_isolation` (tên khớp bản ESPL để dễ
đối chiếu) đặt trong khối Task 3 (đã có fake codex tại ~:2067-2084 và
`capture_task3_codex_launch`). Fixture: thư mục `TMPDIR` riêng cho mỗi ca;
`warnbin/python3` (in cảnh báo confstr ra stderr, `exec` python3 thật);
`failbin/python3` (in chẩn đoán, `exit 1`); dùng `PATH` prefix khi gọi helper.
Các ca = AC1–AC7, mỗi ca assert rc tường minh, nội dung stdout/stderr, fake
codex có/không được gọi, và `TMPDIR` rỗng sau ca. Ca AC9 (reinsertion) thực
hiện trên **bản copy** của helper sinh ra trong fixture (sed `2>"$profile_stderr"`
→ `2>&1`), không sửa nguồn; ghi log RED/GREEN vào `implementation.md`.
Có thể thêm biến `BOOTSTRAP_CODEX_PROFILE_FOCUS_ONLY=true` theo mẫu
`BOOTSTRAP_GUARD_FOCUS_ONLY` để chạy riêng nhanh.

## Edge cases

- Cảnh báo xuất hiện ở **mọi** lần gọi python3 trong launcher (guard,
  preflight) — chỉ `load_model_profile` parse TSV nên chỉ chỗ này cần tách;
  các chỗ khác đã dùng `2>/dev/null` hoặc không parse stdout theo dòng.
- `CODEX_REASONING_EFFORT` override và `CODEX_MODEL_PROFILE` không đổi.
- Lỗi `mktemp` (TMPDIR không ghi được) là lỗi cứng có thông điệp rõ — chấp
  nhận (không có cách tách luồng không cần file mà vẫn giữ Bash 3.2 và thứ tự).
- `MODEL_PROFILE_ERROR` có thể nhiều dòng (cảnh báo + lỗi); `doctor_bad` và
  `status` in được nhiều dòng.

## Non-goals

Không đổi `model-profiles.json`, schema, `allowed_efforts`, audit token
`sol_coding`, README wording, VERSION/MANIFEST (release commit). Không sửa
agent-guard/agent-hook. Không thêm giá trị `ultra`.

## Ràng buộc thứ tự

Packet `guard-hook-deny-ack` đang ở `resolution` với 6 file chưa commit trong
cùng worktree (trong đó có `writers-docs.sh` và file test). Commit packet đó
trước (sau khi sửa 2 backslash ở heredoc `.claude/README.md`), rồi mới bắt đầu
packet này để diff tách bạch; nếu buộc phải làm song song, giữ hunk riêng.

## Verification (Luna ghi rc vào implementation.md)

```bash
bash -n agent-bootstrap/lib/writers-docs.sh && bash -n <target>/.codex/codex-mode.sh
shellcheck --external-sources --exclude=SC1090,SC1091,SC2034,SC2154 <target>/.codex/codex-mode.sh
BOOTSTRAP_CODEX_PROFILE_FOCUS_ONLY=true bash scripts/test-bootstrap-multi-agent-project.sh   # nếu thêm focus flag
bash scripts/sync-template-catalog.sh --check
<target>/.codex/codex-mode.sh doctor && <target>/.codex/codex-mode.sh status && <target>/scripts/verify-ai-deps.sh
bash scripts/test-onboarding-fixtures.sh && bash scripts/test-one-shot-upgrade.sh && bash scripts/test-bootstrap-multi-agent-project.sh
/bin/bash --version | head -1 && /bin/bash -n <target>/.codex/codex-mode.sh && /bin/bash <target>/.codex/codex-mode.sh status   # macOS 3.2
```

Bước chưa chạy ở phía Claude: Bash 3.2 thật; full suite với thay đổi này (chỉ
chạy 6 ca thủ công + reinsertion + shellcheck + bash -n). Không chạy setup trên
project thật; ESPL tự đồng bộ helper của mình sau khi harness-kit merge.

## Specification revision 1

**Quyết định người dùng (2026-09-06):** gộp vào packet này việc chuyển
harness-kit sang **Astra @ ultra** cho planning/reviewing, kèm **đổi tên vai
Sol→Astra toàn bộ** (như ESPL). Coding giữ luna @ xhigh, fallback terra. Token
`policy_exception=sol_coding` giữ nguyên. Phần stderr isolation ở trên giữ
nguyên yêu cầu, chỉ đổi số trường TSV từ 8 thành 11.

### Patch tham khảo (đã chạy xanh)

`evidence/reference-astra-ultra-stderr-combined.patch` (9 file, apply sạch lên
worktree hiện tại; `patch -p1 --dry-run` OK). Đã xác minh trong container
(bash 5.2, non-root): `test-bootstrap-multi-agent-project.sh` rc 0 (488s),
`test-onboarding-fixtures.sh` rc 0, `test-one-shot-upgrade.sh` rc 0,
`sync-template-catalog.sh --check` OK, `bash -n` và shellcheck (exclusions CI)
sạch cho helper + verifier sinh ra; snapshot `agent-hook.sh`/`verify-ai-deps.sh`
== generated. Chi tiết chạy tay: `evidence/claude-prototype-results.md` (mục
Astra bổ sung bên dưới). **Chưa chạy trên macOS bash 3.2** (AC10 giữ nguyên).

### Thiết kế bổ sung

1. **Profile (`model-profiles/codex-model-profiles.json`)** — thêm 3 khóa
   tùy chọn `planning_reasoning_effort`, `coding_reasoning_effort`,
   `reviewing_reasoning_effort` (mặc định = `reasoning_effort` khi thiếu →
   profile v1 cũ vẫn hợp lệ, không bump schema). Default `stable`:
   planning/reviewing = `gpt-6-astra` @ `ultra`; coding = `gpt-5.6-luna` @
   `xhigh`; fallback cả ba = `gpt-5.6-terra`; `reasoning_effort` giữ `xhigh`
   làm mặc định chung. Schema v1: thêm 3 property tùy chọn (không đổi `required`).
2. **Helper sinh ra (`writers-docs.sh` heredoc)** — `allowed_efforts` thêm
   `ultra`; Python phát 11 trường: 8 trường cũ giữ nguyên thứ tự + 3 effort theo
   route ở vị trí 9–11; Bash expect 11; `CODEX_REASONING_EFFORT` (thêm `ultra`)
   ghi đè **cả ba** route cho một lần launch; biến `PLANNING_EFFORT`,
   `CODING_EFFORT`, `REVIEWING_EFFORT`; hàm `effort_for_mode`; `status`, `doctor`,
   launch summary và `exec codex -c model_reasoning_effort=` dùng effort của
   route. Doctor in `effort=<route> (planning=… coding=… reviewing=…)`.
3. **Audit `sol_coding`** — điều kiện chuyển từ chuỗi cứng `gpt-5.6-sol` sang
   `review_route_model "$model"` (model đang launch trùng `reviewing_model` hoặc
   `planning_model` của profile). Token và text `policy_exception=sol_coding
   authorization=user_session` giữ nguyên. Handoff schema thêm một mệnh đề:
   `sol_coding` là định danh ổn định nghĩa là model của route review đang code.
4. **Verifier** — `writers-runtime.sh:752` heredoc + snapshot
   `agent-bootstrap/verify-ai-deps.sh`: 3 khóa effort theo route nếu có mặt phải
   là chuỗi không rỗng.
5. **Đổi tên prose** — `writers-docs.sh` 12 dòng: 1035, 1118, 1171, 1213, 1215,
   1225, 1228, 1237, 1240, 1244 (`a Astra` → `an Astra`), 1253, 1555;
   `README.md` (bước 2 và 4 của flow, câu "authorization entries are audit
   declarations", bảng model routing: astra @ ultra / luna @ xhigh / terra);
   `agent-bootstrap/README.md:77`. Không đụng `docs/superpowers/specs/*` (hồ sơ
   có ngày). Hàm `sol_coding_audit_record` và token giữ tên.
6. **Bù budget (bắt buộc)** — đổi tên làm on-demand +5 token; fixture của Luna
   ở packet trước đã đo 6.200/6.200. Bỏ 4 dòng
   `Config version: \`docs/agent-configs/agent-bootstrap.lock.json\`.` (+ dòng
   trống theo sau) tại `writers-docs.sh` 994, 1194, 1272, 1299 (handoff, mode
   contracts, karpathy, council; lock đã ràng buộc version, không test nào
   assert dòng này). Đo trên cùng fixture: 6.134 → 6.074.
7. **CHANGELOG** — mở rộng mục `## Unreleased`: stderr isolation; Astra @ ultra
   với effort theo route; đổi tên vai Sol→Astra (token `sol_coding` giữ);
   bỏ dòng Config version.

### Test (Luna) — bổ sung vào AC ở trên

- Cập nhật expectation có sẵn (đã nằm trong patch tham khảo):
  bootstrap test 1424, 1426 (`gpt-6-astra`), 1739 (`Astra authorization
  entries…`), 2013, 2024, 2026, 2032, 2046, 2050 (Sol→Astra), 2121/2123
  (`gpt-6-astra default ultra`), 2139 (audit với `CODEX_CODING_MODEL_OVERRIDE=gpt-6-astra`);
  `test-onboarding-fixtures.sh` 124, 174. Không nới assertion nào — mỗi assertion
  đổi đúng chuỗi mới cùng lúc với docs.
- AC12. `capture_task3_codex_launch` thêm: reviewing fallback → `gpt-5.6-terra`
  với effort `ultra`; `CODEX_REASONING_EFFORT=ultra` trên coding → luna @ ultra.
- AC13. Profile có `planning_reasoning_effort: "turbo"` → `unsupported
  planning_reasoning_effort 'turbo'`, không launch. Profile v1 không có 3 khóa →
  status in `planning=xhigh coding=xhigh reviewing=xhigh`.
- AC14. Audit âm tính: `CODEX_CODING_MODEL_OVERRIDE=gpt-5.6-sol` (không còn là
  model của route nào) **không** phát token; `gpt-6-astra` phát token — chứng
  minh điều kiện theo route, không theo chuỗi.
- AC15. Doctor chứa `planning=ultra coding=xhigh reviewing=ultra`; stderr
  isolation case (AC2) chạy với profile Astra, reinsertion báo `expected 11`.
- AC16. Budget: doctor trên fixture suite và trên một target tên dài ≥ 20 ký tự
  đều < 6.200 on-demand; ghi số vào implementation.md.

### Hạn chế đã biết

- Fallback giữ effort của route (terra @ ultra khi planning/reviewing rơi về
  fallback). Nếu terra không nhận `ultra`, dùng
  `CODEX_REASONING_EFFORT=xhigh CODEX_USE_FALLBACK=1` (đã có ví dụ trong
  `.codex/README.md`). Không thêm khóa `*_fallback_reasoning_effort` trong packet này.
- Thứ tự trường TSV của harness-kit (effort ở 9–11) có thể khác fork ESPL; sau
  khi merge, ESPL thay helper fork bằng bản sinh ra (đường candidate) và sửa
  README ESPL theo assertion Astra.

## Specification revision 2

**Thông tin mới (người dùng, 2026-09-06):** `ultra` là effort **chỉ Astra hỗ trợ**.
Revision 1 để fallback và override kế thừa effort của route (terra @ ultra) là
sai. Sửa như sau; patch tham khảo trong `evidence/` đã cập nhật và chạy xanh
lại cả ba suite (bootstrap rc 0 / 359s, onboarding rc 0, one-shot rc 0).

### Quy tắc effort (thay mục 2 của revision 1)

- Effort của route **bind vào model chính của route**: chỉ khi
  `model_source=default` mới dùng `<route>_reasoning_effort`.
- `CODEX_USE_FALLBACK=1` → dùng `<route>_fallback_reasoning_effort` (khóa tùy
  chọn mới, mặc định = `reasoning_effort` của profile, **không** kế thừa effort
  route). Default `stable` ghi rõ cả ba = `xhigh`.
- Model override (`CODEX_MODEL_OVERRIDE` hoặc `CODEX_<MODE>_MODEL_OVERRIDE`) →
  effort = `reasoning_effort` của profile.
- `CODEX_REASONING_EFFORT` (thêm `ultra`) luôn thắng khi được set; nếu giá trị là
  `ultra` mà model hiệu lực không phải model chính của một route có effort
  `ultra`, launcher **cảnh báo** trên stderr rồi vẫn launch (lựa chọn tường minh
  của operator; Codex sẽ từ chối nếu model không hỗ trợ).
- TSV Python phát **14** trường: 8 cũ + 3 effort route + 3 effort fallback;
  Bash expect 14. Schema v1 thêm 3 property tùy chọn
  `*_fallback_reasoning_effort`; verifier kiểm "nếu có mặt thì không rỗng".
- `status`/`doctor` in effort hiệu lực của resolution hiện tại kèm bảng
  `planning/coding/reviewing` và `fallback planning/coding/reviewing`.
- Docs: `.codex/README.md` sinh ra (đoạn Fallback defaults) và `README.md`
  (bảng routing thêm effort cho fallback, một đoạn giải thích ultra Astra-only).
  Không ảnh hưởng budget on-demand (hai file này không được đếm).

### Kết quả kiểm chứng (fake codex, container)

| Launch | Model @ effort |
|---|---|
| planning / reviewing | `gpt-6-astra @ ultra` |
| coding | `gpt-5.6-luna @ xhigh` |
| `CODEX_USE_FALLBACK=1` reviewing / coding | `gpt-5.6-terra @ xhigh` |
| `CODEX_MODEL_OVERRIDE=gpt-5.4` planning | `gpt-5.4 @ xhigh` |
| `CODEX_CODING_MODEL_OVERRIDE=gpt-6-astra` coding | `gpt-6-astra @ xhigh` + token `sol_coding` |
| `CODEX_REASONING_EFFORT=ultra` coding (luna) | `gpt-5.6-luna @ ultra` + **warn** |
| `CODEX_REASONING_EFFORT=ultra` + override astra coding | `gpt-6-astra @ ultra`, không warn |
| `CODEX_REASONING_EFFORT=high CODEX_USE_FALLBACK=1` planning | `gpt-5.6-terra @ high` |

Profile v1 không có khóa effort nào → mọi route và fallback = `xhigh`. Cách ly
stderr, không rò file tạm, verifier `Pass 97 / Warn 5 / Fail 0` giữ nguyên.

### AC cập nhật (thay AC12–AC15 của revision 1)

AC12. `capture_task3_codex_launch`: reviewing fallback → `gpt-5.6-terra` @
`xhigh`; planning override `CODEX_MODEL_OVERRIDE=gpt-5.4` → `xhigh`;
`CODEX_REASONING_EFFORT=high CODEX_USE_FALLBACK=1` planning → `high`.
AC13. `CODEX_REASONING_EFFORT=ultra` trên coding (luna) → launch với `ultra`
**và** stderr chứa `warn: reasoning effort ultra`; cùng biến + override coding
sang `gpt-6-astra` → không có warn. Profile có
`planning_fallback_reasoning_effort: "turbo"` → `unsupported
planning_fallback_reasoning_effort 'turbo'`, không launch. Profile v1 không khóa
effort → status in `planning=xhigh coding=xhigh reviewing=xhigh; fallback
planning=xhigh coding=xhigh reviewing=xhigh`.
AC14. (giữ) audit âm tính với `gpt-5.6-sol`, dương tính với `gpt-6-astra`
(effort khi đó = `xhigh`, không phải `ultra`).
AC15. Doctor chứa `planning=ultra coding=xhigh reviewing=ultra` và
`fallback planning=xhigh`; reinsertion `2>&1` báo `expected 14`.

## Specification revision 3

**Quyết định người dùng (2026-09-06):** ưu tiên cấu hình ghế theo tag
(packet `agent-seats`). Packet này **thu về bug fix stderr isolation** đúng như
spec gốc (TSV 8 trường, `expected 8`); toàn bộ phần revision 1–2 (Astra @ ultra,
effort theo route/fallback, `ultra`, đổi tên Sol→Astra, bỏ dòng Config version)
chuyển sang `agent-seats`, ở đó năng lực effort là dữ liệu catalog thay vì
heuristic. Patch tham khảo áp dụng cho packet này là
`evidence/reference-writers-docs.patch` (stderr-only, đã kiểm 6 ca +
reinsertion); `evidence/reference-astra-ultra-stderr-combined.patch` chỉ còn giá
trị tham khảo cho `agent-seats` (quy tắc effort, danh sách assertion cần đổi).
AC1–AC11 gốc giữ nguyên; AC12–AC16 của revision 1–2 bị huỷ tại đây.

## Combined release resolution — 2026-09-08

The user's combined release authorization supersedes the separate legacy TSV
patch sequence. The final seats launcher implements the stdout/stderr isolation
contract at the seats CLI boundary with eight lossless lines; old profile-parser
field-count wording is superseded by the approved seats interface. No temporary
legacy parser is installed or separately released.

## Outcome

- Summary: valid data with Python diagnostics launches correctly; failures keep
  diagnostics and refuse launch. Temporary files are cleaned and caller traps
  survive. Model/effort changes follow the separately approved seats design.
- Evidence: [combined verification](../agent-seats/verification.md),
  `scripts/test-agent-seats-launcher.py` and its eight groups/three mutations;
  re-merging stderr is caught. macOS Bash 3.2 and all three release suites pass.
- Effect on source: the stderr defect is resolved by the combined seats release
  candidate; historical prototype patches remain reference only.
