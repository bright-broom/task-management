## M2X課題

---

**[システム概要]**

このシステムは工場向けのタスク管理システムです。
工場には設備が複数あり、設備に必要な部品を事前に登録できます。
タスク登録時には設備と部品を設定し、後から設備ごとや部品ごとにタスク数の集計を行うことができます。このシステムはマルチテナントに対応しており、それぞれの環境は、テナントごとに仮想的に分離されていることを想定しています。仕様で分からない箇所があれば、メールでして頂いても問題ありません。

**[課題1]**

以下のUIを参考にテーブル設計をしてください。

**[課題2]**

なんらか追加機能を一つ提案し、それに対応するDB設計も行ってください。

**[提出内容]**

Create Table文やER図のようなテーブル設計が分かるものを提出してください。仮定されたことがあれば、文章で補足を頂きたいです。課題1と課題2は同一の定義にまとめて提出いただいて構いません。冒頭で課題2で追加した機能の概要を説明してください。

---

| 画面名 | 設備詳細画面 | 部品詳細画面 | タスク詳細画面 |
|---|---|---|---|

---

**■ 設備詳細画面**

```
←　　　Equipment Details

Boiler 1

Parent Equipment          Boiler room1

Manufacturer              ABC Company

Description               Regular maintenance is
                          essential for optimal
                          performance.
```

**要件:**
必須項目: 名前

---

**■ 部品詳細画面**

```
←　　　Part Detail

Oil Filter

Model Number              1232-13434AB

Location                  Building 2

Description               HVAC filter

Quantity                  4

Order Point               3

Related Equipment

AC Unit

Boiler 1
```

**要件:**
必須項目: 名前、在庫数

---

**■ タスク詳細画面**

```
←　　　Task Details

Replace the oil in the engine

Status                    todo

Due date
                          Dec 20, 2023

Assigned to               John Smith

Equipment                 Boiler 1

Description

                          Boiler 1 has 237 error.
                          We are fixing it now.

Cause of stoppage         Oil contamination

Repair details

                          Drained old oil, replaced oil filter,
                          flushed system,
                          filled with new oil to proper level

Parts Used

Oil Filter
1232-13434AB
Quantity 1

Oil
#5678
Quantity 3
```

**要件:**
必須項目: タスク名、ステータス

タスクに入力する項目はテナントごとに設定できます。入力する項目自体もテナントごとに独自に作成することができます。
上記の画面では、Cause of stoppageやRepair detailsはテナント独自入力項目です。
