"""Draws results.csv as a before/after chart (log scale) -> query_times_before_after.png"""
import csv
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
rows = list(csv.DictReader(open("results.csv")))
short = {"Q1":"Q1 Customer statement","Q2":"Q2 Agent day summary","Q3":"Q3 Cash-out limit check",
         "Q4":"Q4 Failed-txn queue","Q5":"Q5 Wallet statement","Q6":"Q6 Dispute investigation",
         "Q7":"Q7 LGA monthly volume","Q8":"Q8 Top-10 commission","Q9":"Q9 Rapid cash-out fraud"}
labels = [short[r["query"]] for r in rows][::-1]
b = [float(r["before_ms"]) for r in rows][::-1]; a = [float(r["after_ms"]) for r in rows][::-1]
INK, INK2, GRID, BASE, SURF = "#0b0b0b", "#52514e", "#e1e0d9", "#c3c2b7", "#fcfcfb"
fig, ax = plt.subplots(figsize=(10, 6.2), dpi=200, facecolor=SURF); ax.set_facecolor(SURF)
y = range(len(labels)); h = 0.36
ax.barh([i + h/2 + 0.02 for i in y], b, height=h, color="#eb6834", label="Before (PK/UNIQUE only)")
ax.barh([i - h/2 - 0.02 for i in y], a, height=h, color="#2a78d6", label="After indexes.sql")
for i, (bv, av) in enumerate(zip(b, a)):
    ax.text(bv * 1.12, i + h/2 + 0.02, f"{bv:,.0f} ms", va="center", fontsize=8, color=INK2)
    ax.text(av * 1.12, i - h/2 - 0.02, (f"{av:,.2f} ms  ({bv/av:,.0f}×)" if bv/av >= 10 else f"{av:,.2f} ms  ({bv/av:.1f}×)") if bv/av >= 10 else f"{av:,.2f} ms  ({bv/av:.1f}×)", va="center", fontsize=8, color=INK)
ax.set_xscale("log"); ax.set_xlim(0.01, 5000)
ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{v:g}"))
ax.set_yticks(list(y)); ax.set_yticklabels(labels, fontsize=9, color=INK)
ax.set_xlabel("Median execution time, ms (log scale, 5 warm runs)", color=INK2, fontsize=9)
ax.grid(axis="x", color=GRID, linewidth=0.6); ax.set_axisbelow(True)
for s in ["top", "right", "left"]: ax.spines[s].set_visible(False)
ax.spines["bottom"].set_color(BASE); ax.tick_params(colors=INK2, length=0)
ax.set_title("AgentLink Lagos: query time before vs after indexing (1.2M transactions)",
             loc="left", fontsize=11, color=INK, pad=26)
ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2, frameon=False, fontsize=8.5)
plt.tight_layout(); plt.savefig("query_times_before_after.png", facecolor=SURF)
