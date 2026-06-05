# Merge / Grouping Gate 1 + Gate 2 — Plain-English Checklist

Generated 2026-06-05 BKK. ไว้สำหรับพี่ Junior อ่านก่อน fill attestation.
ไม่ใช่ technical spec — เน้นอธิบายให้เข้าใจว่าทำไมต้องเช็ค, เช็คอะไร,
แล้วถ้าไม่แน่ใจให้ตอบยังไง.

ไม่มีการเปลี่ยน code, ไม่มี SQL, ไม่มี deploy, ไม่มี restart.

---

## 1. Merge / Grouping กำลังจะทำอะไร (สั้น ๆ)

พี่เปิด trade ตัวเดียวกันหลายไม้ — เช่น Long S50M26 3 ไม้ + Long S50U26
2 ไม้ = ทั้งหมด 5 ไม้ในแผนเดียว.

Feature ใหม่จะให้พี่:

- เลือก 5 ไม้นี้ → กด `[+ Group]` → แสดงเป็น **กลุ่มเดียว** ในตาราง
- ดู summary ของกลุ่ม: total qty, weighted avg entry, P/L รวม
- กางออกดูแต่ละไม้ได้, ปิดทีละไม้ได้, แก้ทีละไม้ได้ ตามเดิม
- กด ungroup กลับเป็น 5 ไม้แยกได้ทุกเมื่อ

**สิ่งที่ feature ใหม่จะ "ไม่" ทำเด็ดขาด:**

- ไม่ลบไม้เก่า
- ไม่สร้าง "trade ปลอม" 1 ไม้แทน 5 ไม้
- ไม่ซ่อนไม้เก่าใน reducer ไหนเลย
- ไม่ทำให้ P/L รวมผิด

ไม้ดั้งเดิม 5 ไม้ยังเป็น row จริงใน database. Group เป็นแค่ **label
กับ note** ที่บอกว่า 5 ไม้นี้คือไอเดียเดียวกัน.

---

## 2. ทำไมเรื่องนี้ถึง sensitive

Merge เก่า (ที่ถูก disable ไปแล้ว) เคยพังแบบ silent:

- มันสร้าง row ใหม่ ("merged trade") เพิ่ม
- แล้ว mark row เดิมว่า `_hiddenByMerge:true`
- **แต่ไม่มี code ตรงไหนเลยที่ filter ออก `_hiddenByMerge`**
- ทุกฟังก์ชันคำนวณ P/L (Dashboard, Calendar, Steps, HWM, Sheets sync)
  เลยนับทั้งของเก่า **และ** ของใหม่ → realized profit **คูณ 2 เงียบ ๆ**

ปัญหาคือมันเงียบ. ไม่มี error, ไม่มี alert. พี่จะคิดว่าทำกำไรเยอะกว่าจริง.

design ใหม่จึงเลือกแบบที่ **บังคับให้ผิดยาก**: ไม่มี row ปลอม,
group เป็น metadata ล้วน, reducer ทั้งหมดยังเดินบน raw trades[] เหมือนเดิม.

แต่ก่อนจะเริ่มเพิ่ม layer ใหม่บน trade rows → เราต้องแน่ใจก่อนว่าระบบ
save trade ปัจจุบัน **ไม่ได้พังเงียบ ๆ อยู่แล้ว**. นี่คือสิ่งที่ Gate
1 + Gate 2 ตรวจ.

---

## 3. Gate 1 คืออะไร — แบบง่าย ๆ

**ภาษาคน:** ใน 14 วันที่ผ่านมา ตอนพี่ใช้ thus999.com ปกติ
ไม่ควรมี warning ในเครื่องว่า "ส่งข้อมูล save trade ไปแล้วแต่ server
ไม่รับ (เขียน 0 rows)".

**ภาษา technical สั้น ๆ:**

App มี tripwire ติดอยู่ที่ `index.html:251-255`:

```
console.warn("[trades][write] upserted-affected=0/N — POSSIBLE RLS / CONSTRAINT DENIAL")
```

ถ้า message นี้ขึ้นในช่วง 14 วัน = แปลว่า save trade ของพี่มีบางครั้ง
ไม่เข้า DB จริง (RLS deny, constraint mismatch, etc.) → ระบบ persistence
ยังไม่ stable → ห้ามเพิ่ม schema ใหม่ทับ.

**Gate 1 ถาม:** ใน 14 วันที่ผ่านมาเคยเห็น `upserted-affected=0/`
ใน console ของ thus999.com มั้ย?

---

## 4. Gate 2 คืออะไร — แบบง่าย ๆ

**ภาษาคน:** ลองลบ trade ทุกตัวจนเหลือ 0 → refresh หน้า → ยังคงเป็น
0 trades ใช่มั้ย? ไม่ใช่ว่าหลัง refresh ไม้เก่ากลับมาเงียบ ๆ ใช่มั้ย?

**ทำไมต้องเช็ค:** เคยมี bug ชื่อ P0-1. ใน `db.saveTrades` ตอน input
trades array เป็น `[]` มัน short-circuit return ทันที — ไม่ส่ง
delete ไปบอก server ว่า user ลบหมดแล้ว → server เก็บ row เดิมไว้ →
refresh แล้ว row กลับมา → พี่เสียทรัพย์.

Bug นี้แก้แล้ว (`index.html:230-247` — "empty-array MUST fall through
so reconcile-delete can propagate 'user deleted their last trade' to
the server").

**แต่** code-fix นี้ถูก deploy แล้ว และ **มีคนทดสอบบนของจริง
(thus999.com) จริง ๆ มั้ย?**

**Gate 2 ถาม:** ใน build ที่ deploy อยู่ปัจจุบัน เคยลบ trade
ทุกตัว → refresh → ยืนยันว่ายังเหลือ 0 ใช่มั้ย? (หรืออย่างน้อย
มี confidence ว่า code path นี้ถูก ผ่าน DevTools sanity check?)

---

## 5. พี่ต้องเช็คอะไรบ้าง — manual checklist

### สำหรับ Gate 1

ตัวเลือก A (ดีที่สุด) — **Supabase logs dashboard**:

1. Login Supabase dashboard
2. ไปที่ project `wtfwynvvkiuottjnmozu` → Logs → Postgres logs (หรือ
   PostgREST request logs)
3. Filter: table = `trades`, method = UPDATE หรือ INSERT
4. ดูช่วง 14 วันย้อนหลัง
5. เห็น RLS denials หรือ 4xx errors บน `trades` มั้ย?

ตัวเลือก B — **Browser DevTools console**:

1. เปิด thus999.com ใน Chrome
2. กด F12 → tab Console
3. Filter search: `upserted-affected=0/` (ใส่ในช่อง filter ล่างซ้าย)
4. ถ้า console ของ session ปัจจุบันยังเก็บ log เก่าอยู่ → ดูว่ามี
   message นี้มั้ย
5. ถ้า history ถูก clear ไปแล้ว → ตัวเลือกนี้ทำไม่ได้ → ใช้ตัวเลือก A

ตัวเลือก C — **ยอมรับโดยจำได้**:

ถ้าพี่จำได้ว่าใน 14 วันที่ผ่านมา save trade ทุกครั้งสำเร็จ ไม่มี
trade หาย, ไม่มี Supabase error tab ขึ้น, ทุกอย่างปกติ → ก็เป็น
weak evidence ระดับนึง. แต่ไม่ strong เท่าตัวเลือก A.

### สำหรับ Gate 2

ตัวเลือก A (ดีที่สุดถ้าทำได้) — **destructive smoke บน test account**:

1. สร้าง test user แยก (ถ้ายังไม่มี)
2. Login เข้า thus999.com ด้วย test user
3. เพิ่ม trade test 2-3 ไม้
4. ลบทีละไม้จนเหลือ 0
5. Hard refresh (Ctrl+Shift+R)
6. ยืนยัน Positions = ว่าง, Closed Journal = ว่าง
7. เช็ค Supabase: `SELECT count(*) FROM trades WHERE user_id = <test_uid>`
   ต้องได้ 0
8. เปิด DevTools console — **ไม่ควร** เห็น `upserted-affected=0/0`
   (เพราะ empty path ข้ามขั้น upsert ไปเลย)

ตัวเลือก B — **destructive smoke บน real account** (พี่จริง):

ทำเหมือนตัวเลือก A แต่บน real account ของพี่. **เสี่ยง** — ถ้าทำผิด
จะเสียประวัติเทรดจริง. แนะนำให้ backup `phase2b_backup_payload.json`
style ก่อนเริ่ม.

ตัวเลือก C (ปลอดภัยที่สุดถ้าไม่อยากลบจริง) — **code-path reasoning +
DevTools sanity check**:

1. อ่าน `index.html:230-247` (empty-array fall-through fix)
2. เปิด DevTools → Sources → set breakpoint ที่ line 234 (`if(!trades)`)
3. Trigger save ปกติ (เปิด/ปิด trade 1 ตัว)
4. ยืนยัน breakpoint hit, `trades` parameter ไม่เป็น `null`
5. Disable breakpoint
6. อ่าน line 257-263 (reconcile-delete) — verify logic: ถ้า
   `localIds` ว่าง และ `knownIds` มี ID → `removedIds` = ของใน
   `knownIds` ทั้งหมด → จะถูก delete ออกหมด
7. **ไม่** ลบ trade จริง. เขียนใน attestation ว่าใช้วิธี code-path
   reasoning

ตัวเลือก D — **deferred to natural use**:

ถ้าวันไหนพี่ตั้งใจจะลบ trade เก่าออกอยู่แล้ว → จดไว้ก่อน → ตอนลบให้
สังเกตว่า refresh แล้วยังเหลือ 0 จริงมั้ย → จดผลใน attestation.
ไม่ต้องลบเพิ่มเพื่อ smoke โดยเฉพาะ.

---

## 6. อะไรนับเป็น PASS

**Gate 1 = PASS เมื่อ:**

- พี่ได้เปิดดู source หนึ่งใน (A) Supabase logs / (B) DevTools console
  history / (C) จำได้ว่าไม่มีปัญหา
- ช่วงเวลาที่ดู ≥ 14 วัน
- จำนวน `upserted-affected=0/` ที่เห็น = **0**
- พี่ confident พอที่จะเขียนใน attestation

**Gate 2 = PASS เมื่อ:**

- พี่ได้ทำตัวเลือก A / B / C / D อย่างใดอย่างหนึ่ง
- ผลคือ empty state persisted ถูกต้อง (หรือ code path ตรวจแล้วถูก)
- ไม่เห็น `upserted-affected=0/0` ใน console
- พี่ confident พอที่จะเขียนใน attestation

---

## 7. อะไรนับเป็น INSUFFICIENT

**Gate 1 = INSUFFICIENT เมื่อ:**

- พี่ไม่ได้ดู (ยังไม่มีเวลา / ไม่รู้จะดูที่ไหน)
- ดูแล้วแต่ window สั้นกว่า 14 วัน
- DevTools history ถูก clear ไปแล้ว และไม่อยาก login Supabase logs
- ไม่แน่ใจว่ามีหรือไม่มี `affected=0`

**Gate 2 = INSUFFICIENT เมื่อ:**

- พี่ยังไม่ได้ลอง smoke (และยังไม่อยาก destructive run)
- ไม่ได้อ่าน code path
- เคย deploy แต่ไม่ได้ verify ตอนนั้น และจำไม่ได้
- ไม่อยาก smoke ตอนนี้ — รอ natural use

**สำคัญ:** INSUFFICIENT **ไม่ใช่ FAIL**. มันแปลว่า "เรายังไม่รู้คำตอบ".
FAIL คือ "เรารู้คำตอบแล้วและมันแย่". อย่าสับสนกัน.

---

## 8. ทำไมพี่ไม่ควร mark PASS โดยไม่มี evidence

3 เหตุผล:

1. **ถ้าระบบ save trade ปัจจุบันพังเงียบ ๆ อยู่แล้ว** แล้วเพิ่ม schema
   `trade_groups` + `group_id` เข้าไป → bug ใหม่จะปนกับ bug เก่า →
   debug ยากขึ้นมาก. Gate ป้องกัน compound failure.

2. **Audit trail** — attestation นี้จะถูก commit ไว้เป็นหลักฐาน. ถ้า
   วันหลัง G3 ship แล้วเจอ data anomaly → review attestation นี้
   ก่อนเป็นอันดับแรก. ถ้าเขียน PASS โดยไม่ได้ดูจริง → attestation
   trail เสียหาย → ไม่รู้จะเริ่ม debug ตรงไหน.

3. **มันแค่ template** — ถ้ายังไม่พร้อม, mark INSUFFICIENT, ปล่อย G1
   ค้างไว้, ทำเรื่องอื่นไปก่อน. ไม่มี cost. แต่ mark PASS ผิดมี cost
   จริง.

---

## 9. ถ้าทั้ง 2 gate PASS แล้วจะเกิดอะไร

ลำดับงานหลังจากนั้น:

1. **Junior commit attestation file** ที่กรอกเสร็จ
2. **G1 task** — เขียน migration SQL อย่างเดียว (ไม่มี app code):
   - `CREATE TABLE trade_groups (...)`
   - `ALTER TABLE trades ADD COLUMN group_id ...`
   - RLS policies
   - Indexes
   - Inline verification snippets
   - Inline rollback
   - ใช้ `IF NOT EXISTS` ทุกอันให้ rerun-safe
3. **Junior review migration SQL** ใน text editor ก่อน
4. **Junior run migration** ใน Supabase SQL Editor (manually copy-paste)
5. **Verify** ว่า app ยัง work ปกติ (column `group_id` ยังว่าง, ไม่มีใคร
   อ่าน) — เรียกว่า "dormant column" phase
6. **G2 task** — เพิ่ม `GroupCard` แบบ read-only display อย่างเดียว
7. **G3 task** — เพิ่มปุ่ม `[+ Group]` + ungroup UI + ลบ dead Merge code
8. **G4** — group notes
9. **G5** — `[Insert GUGU summary]` button
10. **G6** — legacy `isMerged` cleanup

ระหว่าง G1 → G3 พี่จะมี several review checkpoints. ไม่ใช่
shipping 100% ครั้งเดียว.

---

## 10. ถ้า INSUFFICIENT จะเกิดอะไร

**ไม่มีอะไรเสียหาย.** G1 ค้างไว้, รอวันที่พี่พร้อม. ทำเรื่องอื่นแทน
(Capture Bot expansion, GUGU lifecycle redesign, Notes curation, etc.).

วันไหนพร้อมเช็ค:

- เปิด `gate_1_2_junior_attestation_20260605.md` (หรือสร้างไฟล์ใหม่
  ด้วยวันที่ปัจจุบัน)
- กรอกใหม่
- commit
- เริ่ม G1

ไม่มี deadline. ไม่มี penalty. Gate ออกแบบมาเพื่อรอ.

---

## 11. คำแนะนำถ้าพี่ไม่แน่ใจ

ถ้าตอนนี้พี่ยังไม่แน่ใจ / ยังไม่มีเวลาเช็ค / ไม่อยากเสี่ยง smoke จริง:

**ตอบนี้ใน attestation:**

```
Gate 1 = INSUFFICIENT
Gate 2 = INSUFFICIENT
G1 schema/RLS remains blocked.
```

**คำอธิบายสำหรับช่อง Junior notes:**

```
ยังไม่ได้ verify ครับ. Defer G1 จนกว่าจะมีเวลา check Supabase logs
และ run Block 5 smoke (หรือ code-path review) ตามเอกสาร
gate_1_2_plain_english_checklist.md.
```

นี่เป็นคำตอบที่ปลอดภัยที่สุด. มันบอกความจริง, ไม่บล็อก future work,
และยังเก็บ audit trail ครับ.

Stop.
