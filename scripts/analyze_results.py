"""Обработка результатов эксперимента SOS-013 / WIN-061 (п. 4.7 протокола).

Читает каталог results, созданный 03-Host-RunAll.ps1 (учитываются только серии с done.txt),
и для каждой комбинации "интенсивность притока x расписание" считает медиану, IQR и CV
показателей по повторам, а также точный двусторонний U-критерий Манна - Уитни
для среднего объема неоптимизированных данных перед запуском задания.

Результаты (каталог --out):
    summary.csv       - сводная таблица по всем показателям (открывается в Excel);
    summary.txt       - то же в текстовом виде и результаты U-критерия;
    stats.txt         - стратифицированный перестановочный тест, поправка Холма, величина эффекта,
                        доверительные интервалы Ходжеса - Лемана, мощность, анализ без серий с 4 ГБ ОЗУ,
                        проверка метрики и влияния WSB;
    fig6_dynamics.png - объем неоптимизированных данных в течение серии (рисунок 6 статьи);
    fig7_prejob.png   - средний объем перед запуском задания по повторам (рисунок 7);
    fig8_jobtime.png  - длительность заданий оптимизации (рисунок 8).

Запуск (из папки со скриптами):
    python analyze_results.py --results results

Нужны пакеты numpy и matplotlib: pip install numpy matplotlib
"""
import argparse
import csv
import glob
import itertools
import json
import os
import sys
from collections import Counter, defaultdict

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

METRICS = ["mean_prejob", "mean_time", "peak", "job_mean_min", "job_total_min", "savings", "wsb_size", "wsb_time"]
NAMES = {"mean_prejob": "Средний объём перед запуском, ГБ",
         "mean_time": "Среднее по времени, ГБ",
         "peak": "Пик, ГБ",
         "job_mean_min": "Время одного задания, мин",
         "job_total_min": "Время заданий за серию, мин",
         "savings": "Эффективная экономия (доля)",
         "wsb_size": "Копия WSB, ГБ",
         "wsb_time": "Копия WSB, мин"}
SCHEDS = ("daily", "weekly")
LAB = {"daily": "Ежедневно", "weekly": "Еженедельно"}
C = {"daily": "#025e1f", "weekly": "#4e9a5e"}      # цвета оформления AU


# ---------------------------------------------------------------- статистика
def stats(vals):
    v = np.array([x for x in vals if x is not None and not np.isnan(x)], dtype=float)
    if len(v) == 0:
        return dict(med=np.nan, q1=np.nan, q3=np.nan, iqr=np.nan, cv=np.nan, n=0)
    q1, med, q3 = np.percentile(v, [25, 50, 75])
    cv = v.std(ddof=1) / v.mean() * 100 if len(v) > 1 and v.mean() != 0 else np.nan
    return dict(med=med, q1=q1, q3=q3, iqr=q3 - q1, cv=cv, n=len(v))


def mann_whitney_exact(a, b):
    """Точный двусторонний U-критерий: перебор всех разбиений рангов на две группы."""
    a, b = list(a), list(b)
    n1, n2 = len(a), len(b)
    allv = a + b
    order = sorted(range(n1 + n2), key=lambda i: allv[i])
    ranks = [0.0] * (n1 + n2)
    i = 0
    while i < len(order):                     # при совпадениях - средний ранг
        j = i
        while j + 1 < len(order) and allv[order[j + 1]] == allv[order[i]]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2 + 1
        i = j + 1

    def u_of(idx):
        return sum(ranks[k] for k in idx) - n1 * (n1 + 1) / 2

    u_obs = u_of(range(n1))
    dist = [u_of(c) for c in itertools.combinations(range(n1 + n2), n1)]
    lo = sum(1 for u in dist if u <= u_obs + 1e-9) / len(dist)
    hi = sum(1 for u in dist if u >= u_obs - 1e-9) / len(dist)
    return min(u_obs, n1 * n2 - u_obs), min(1.0, 2 * min(lo, hi))


# ---------------------------------------------------------------- загрузка
def num(x):
    try:
        return float(str(x).strip().replace(",", "."))
    except (TypeError, ValueError):
        return np.nan


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f, delimiter=";"))


def load_results(rdir, min_ram=0):
    """Метрики каждого повтора по файлам завершенных серий (min_ram > 0 - только серии с ОЗУ ВМ не меньше)."""
    done = sorted(os.path.dirname(p) for p in glob.glob(os.path.join(rdir, "*", "done.txt")))
    if min_ram > 0:
        def ram_of(d):
            with open(os.path.join(d, "meta.json"), encoding="utf-8-sig") as f:
                return float(json.load(f).get("RamGB", 0))
        skipped = [os.path.basename(d) for d in done if ram_of(d) < min_ram - 0.5]
        done = [d for d in done if ram_of(d) >= min_ram - 0.5]
        if skipped:
            print("Исключены серии с ОЗУ ВМ меньше", min_ram, "ГБ:", ", ".join(skipped))
    if not done:
        sys.exit(f"В каталоге {rdir} нет завершенных серий (папок с done.txt).")
    print(f"Завершенных серий: {len(done)}")
    runs, events, wsb, metas = [], [], [], {}
    for d in done:
        runs += read_csv(os.path.join(d, "runs.csv"))
        events += read_csv(os.path.join(d, "events.csv"))
        wsb += read_csv(os.path.join(d, "wsb.csv"))
        mp = os.path.join(d, "meta.json")
        if os.path.exists(mp):
            with open(mp, encoding="utf-8-sig") as f:
                metas[os.path.basename(d)] = json.load(f)

    # объем ОЗУ ВМ по сериям (при нехватке памяти на хосте часть серий могла идти с меньшим объемом)
    ram = {k: round(float(m["RamGB"])) for k, m in metas.items() if m.get("RamGB")}
    if ram:
        main_ram = Counter(ram.values()).most_common(1)[0][0]
        other = sorted(k for k, v in ram.items() if v != main_ram)
        print(f"ОЗУ ВМ: {main_ram} ГБ" + (f"; другой объем в сериях: {', '.join(f'{k} ({ram[k]} ГБ)' for k in other)}" if other else ""))
    days = int(next(iter(metas.values())).get("Days", 14)) if metas else 14

    def key(r):
        return num(r["IntensityGB"]), r["Schedule"].strip().lower(), int(num(r["Repeat"]))

    R, E, W = defaultdict(list), defaultdict(list), defaultdict(list)
    for r in runs:
        R[key(r)].append(r)
    for r in events:
        E[key(r)].append(r)
    for r in wsb:
        W[key(r)].append(r)

    results = defaultdict(list)
    for k in sorted(R):
        rr = sorted(R[k], key=lambda r: int(num(r["Day"])))
        pre = [num(r["UnoptimizedGB"]) for r in rr]
        jm = [num(r["JobMinutes"]) for r in rr]
        # почасовая сетка по журналу событий: значение держится до следующего события
        prio = {"start": 0, "job": 1, "intake": 2}
        ev = sorted(E.get(k, []), key=lambda r: (int(num(r["Day"])), int(num(r["Hour"])), prio.get(r["Event"], 3)))
        hourly, sav = [], []
        u = lg = sv = np.nan
        idx = 0
        for t in range(days * 24 if ev else 0):
            d, h = t // 24 + 1, t % 24
            while idx < len(ev) and (int(num(ev[idx]["Day"])), int(num(ev[idx]["Hour"]))) <= (d, h):
                u, lg, sv = num(ev[idx]["UnoptimizedGB"]), num(ev[idx]["LogicalGB"]), num(ev[idx]["SavedGB"])
                idx += 1
            hourly.append(u)
            sav.append(sv / lg if lg else np.nan)
        start = [num(e["LogicalGB"]) for e in ev if e["Event"] == "start"]
        prev = [start[0] if start else np.nan] + [num(r["LogicalGB"]) for r in rr[:-1]]
        intake = [num(r["LogicalGB"]) - pv for r, pv in zip(rr, prev)]     # записано с прошлого запуска
        ok = [w for w in W.get(k, []) if int(num(w.get("ExitCode", 0)) or 0) == 0]
        size = [num(w["ImageGB"]) if num(w["ImageGB"]) > 0 else num(w["UsedGB"]) for w in ok]
        wt = [num(w["Minutes"]) for w in ok]
        results[(k[0], k[1])].append(dict(
            repeat=k[2], n_jobs=len(pre), prejob=pre, hourly=hourly,
            days=[int(num(r["Day"])) for r in rr], jobs=jm, intake=intake,
            residual=[num(r["ResidualGB"]) for r in rr],
            status=[num(r.get("StatusUnoptGB")) for r in rr],
            mean_prejob=float(np.nanmean(pre)),
            mean_time=float(np.nanmean(hourly)) if hourly else np.nan,
            peak=float(np.nanmax(hourly + pre)),
            job_mean_min=float(np.nanmean(jm)),
            job_total_min=float(np.nansum(jm)),
            savings=float(np.nanmean(sav)) if sav else np.nan,
            wsb_size=float(np.mean(size)) if size else np.nan,
            wsb_time=float(np.mean(wt)) if wt else np.nan))
    return dict(results), days


def summarize(results):
    S = {k: {m: stats([r[m] for r in reps]) for m in METRICS} for k, reps in results.items()}
    tests = {}
    for I in sorted({k[0] for k in results}):
        if (I, "daily") in results and (I, "weekly") in results:
            tests[I] = mann_whitney_exact([r["mean_prejob"] for r in results[(I, "daily")]],
                                          [r["mean_prejob"] for r in results[(I, "weekly")]])
    return S, tests


# ---------------------------------------------------------------- дополнительный анализ
_UD = {}


def u_dist(n1, n2):
    """Число перестановок с каждым значением U (точное распределение без совпадений)."""
    if (n1, n2) in _UD:
        return _UD[(n1, n2)]
    if n1 == 0 or n2 == 0:
        res = [1]
    else:
        a, b = u_dist(n1 - 1, n2), u_dist(n1, n2 - 1)
        res = [0] * (n1 * n2 + 1)
        for u, c in enumerate(a):
            res[u + n2] += c
        for u, c in enumerate(b):
            res[u] += c
    _UD[(n1, n2)] = res
    return res


def u_stat(a, b):
    """U для гипотезы b > a: число пар (a_i, b_j) с b_j > a_i (совпадения - 0,5)."""
    return sum((y > x) + 0.5 * (y == x) for x in a for y in b)


def stratified_test(groups):
    """Стратифицированный перестановочный тест (сумма U по стратам), двусторонний, точный.
    groups - список пар (a, b) по стратам."""
    dist = {0: 1}
    t_obs, mean = 0.0, 0.0
    for a, b in groups:
        n1, n2 = len(a), len(b)
        t_obs += u_stat(a, b)
        mean += n1 * n2 / 2
        nd = defaultdict(int)
        for t, c in dist.items():
            for u, cu in enumerate(u_dist(n1, n2)):
                nd[t + u] += c * cu
        dist = nd
    total = sum(dist.values())
    dev = abs(t_obs - mean)
    p = sum(c for t, c in dist.items() if abs(t - mean) >= dev - 1e-9) / total
    return t_obs, p, total


def holm(pvals):
    order = sorted(range(len(pvals)), key=lambda i: pvals[i])
    adj, run = [0.0] * len(pvals), 0.0
    for rank, i in enumerate(order):
        run = max(run, min(1.0, (len(pvals) - rank) * pvals[i]))
        adj[i] = run
    return adj


def effect_r(a, b):
    """r = |Z| / sqrt(N) по нормальному приближению U и рангово-бисериальная корреляция."""
    n1, n2 = len(a), len(b)
    u = u_stat(a, b)
    z = (u - n1 * n2 / 2) / np.sqrt(n1 * n2 * (n1 + n2 + 1) / 12)
    return abs(z) / np.sqrt(n1 + n2), 2 * u / (n1 * n2) - 1


def hodges_lehmann(a, b, level=0.95, log=False):
    """Оценка Ходжеса - Лемана сдвига b - a (или отношения b / a при log=True) и точный ДИ."""
    if log:
        a, b = np.log(a), np.log(b)
    d = sorted(y - x for x in a for y in b)
    n1, n2 = len(a), len(b)
    dist = u_dist(n1, n2)
    total = sum(dist)
    cdf, k = 0, 0
    while k < len(dist) and (cdf + dist[k]) / total <= (1 - level) / 2:
        cdf += dist[k]
        k += 1
    k = max(k, 1)
    lo, hi = d[k - 1], d[len(d) - k]
    achieved = 1 - 2 * sum(dist[:k]) / total          # покрытие интервала [d(k); d(mn-k+1)]
    est = float(np.median(d))
    if log:
        return np.exp(est), np.exp(lo), np.exp(hi), achieved
    return est, lo, hi, achieved


def mw_p(a, b):
    n1, n2 = len(a), len(b)
    dist = u_dist(n1, n2)
    total = sum(dist)
    u = u_stat(a, b)
    dev = abs(u - n1 * n2 / 2)
    return sum(c for v, c in enumerate(dist) if abs(v - n1 * n2 / 2) >= dev - 1e-9) / total


def power(results, n, alpha=0.05, sims=2000, seed=1):
    """Мощность (доля значимых исходов) при n повторах: нормальная модель с оценками среднего и SD по данным."""
    rng = np.random.default_rng(seed)
    Is = sorted({k[0] for k in results})
    par = {k: (np.mean([r["mean_prejob"] for r in v]), np.std([r["mean_prejob"] for r in v], ddof=1))
           for k, v in results.items()}
    ok_strat = ok_holm = 0
    for _ in range(sims):
        groups, ps = [], []
        for I in Is:
            a = rng.normal(*par[(I, "daily")], n)
            b = rng.normal(*par[(I, "weekly")], n)
            groups.append((list(a), list(b)))
            ps.append(mw_p(a, b))
        ok_strat += stratified_test(groups)[1] < alpha
        ok_holm += all(p < alpha for p in holm(ps))
    return ok_strat / sims, ok_holm / sims


def extended_analysis(results, results8, out):
    L = []
    Is = sorted({k[0] for k in results})

    def block_tests(res, title):
        L.append(title)
        groups = [([r["mean_prejob"] for r in res[(I, "daily")]], [r["mean_prejob"] for r in res[(I, "weekly")]])
                  for I in Is]
        t, p, total = stratified_test(groups)
        L.append(f"  Стратифицированный перестановочный тест (страты - интенсивность): T = {t:g}, "
                 f"перестановок {total}, p = {p:.5f}")
        ps = [mw_p(a, b) for a, b in groups]
        adj = holm(ps)
        for I, (a, b), pv, pa in zip(Is, groups, ps, adj):
            r, rb = effect_r(a, b)
            hl = hodges_lehmann(a, b)
            hr = hodges_lehmann(a, b, log=True)
            L.append(f"  Приток {gb(I)} ГБ/сут: n = {len(a)}/{len(b)}, U-тест p = {pv:.4f}, по Холму p = {pa:.4f}; "
                     f"r = {r:.2f}, ранг.-бисер. = {rb:.2f}; разница медиан (Х-Л) {hl[0]:.2f} ГБ, "
                     f"ДИ {hl[3] * 100:.1f} % [{hl[1]:.2f}; {hl[2]:.2f}]; отношение {hr[0]:.2f}, "
                     f"ДИ [{hr[1]:.2f}; {hr[2]:.2f}]")
        L.append("")

    block_tests(results, "1. Проверка гипотезы, все завершенные серии")
    block_tests(results8, "2. Анализ чувствительности: только серии с 8 ГБ ОЗУ ВМ")

    L.append("3. Мощность (моделирование, 2000 повторений, нормальная модель по данным)")
    for n in (4, 5, 8):
        ps, ph = power(results, n)
        L.append(f"  n = {n}: стратифицированный тест (альфа 0,05) {ps * 100:.0f} %, "
                 f"оба сравнения по Холму {ph * 100:.0f} %")
    L.append("")

    L.append("4. Проверка метрики: объем перед запуском против объема, записанного с прошлого запуска")
    diff, resid, st = [], [], []
    for reps in results.values():
        for r in reps:
            diff += [p - i for p, i in zip(r["prejob"], r["intake"]) if not np.isnan(i)]
            resid += r["residual"]
            st += [(p, s) for p, s in zip(r["prejob"], r["status"]) if not np.isnan(s)]
    diff = np.array(diff)
    L.append(f"  запусков: {len(diff)}; расхождение: среднее {diff.mean() * 1024:.2f} МБ, "
             f"макс. по модулю {np.abs(diff).max() * 1024:.2f} МБ")
    L.append(f"  остаток после задания: макс. {max(resid) * 1024:.2f} МБ")
    if st:
        a = np.array(st)
        L.append(f"  сравнение с Get-DedupStatus (InPolicy - Optimized): {len(a)} запусков, корреляция "
                 f"{np.corrcoef(a[:, 0], a[:, 1])[0, 1]:.4f}, среднее расхождение {np.mean(a[:, 1] - a[:, 0]):.3f} ГБ")
    else:
        L.append("  данных Get-DedupStatus перед запуском в этих сериях нет")
    L.append("")

    L.append("5. Влияние копии WSB: ежедневное расписание, задания 7-х и 14-х суток (сразу после копий 6-х и 13-х суток) против остальных")
    for I in Is:
        for res, title in ((results, "все серии"), (results8, "8 ГБ ОЗУ")):
            if (I, "daily") not in res:
                continue
            after, other, pr_after, pr_other = [], [], [], []
            for r in res[(I, "daily")]:
                for d, j, p, i in zip(r["days"], r["jobs"], r["prejob"], r["intake"]):
                    (after if d in (7, 14) else other).append(j)
                    (pr_after if d in (7, 14) else pr_other).append(p / i if i else np.nan)
            L.append(f"  {gb(I)} ГБ/сут ({title}): длительность задания после копии: медиана {np.median(after):.2f} мин "
                     f"(n = {len(after)}), в остальные сутки {np.median(other):.2f} мин (n = {len(other)}); "
                     f"объем перед запуском / записано: {np.nanmedian(pr_after):.4f} и {np.nanmedian(pr_other):.4f}; "
                     f"U-тест по длительности p = {mw_p(other, after):.4f}")
    L.append("")

    L.append("6. Показатели времени: все серии и только 8 ГБ ОЗУ (медиана [IQR], CV)")
    for m in ("job_mean_min", "job_total_min", "wsb_time"):
        for k in sorted(results):
            s1 = stats([r[m] for r in results[k]])
            s2 = stats([r[m] for r in results8.get(k, [])])
            L.append(f"  {NAMES[m]:30s} {gb(k[0]):>2s} {k[1]:7s} все: {s1['med']:.1f} [{s1['iqr']:.1f}], "
                     f"CV {s1['cv']:.1f} %, n = {s1['n']};  8 ГБ: {s2['med']:.1f} [{s2['iqr']:.1f}], "
                     f"CV {s2['cv']:.1f} %, n = {s2['n']}")
    with open(os.path.join(out, "stats.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    print("\n".join(L))


# ---------------------------------------------------------------- вывод
def gb(x):
    return f"{x:g}".replace(".", ",")


def write_summary(results, S, tests, out):
    lines = []
    with open(os.path.join(out, "summary.csv"), "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["Показатель", "Приток, ГБ/сут", "Расписание", "n", "Медиана", "Q1", "Q3", "IQR", "CV, %",
                    "Значения по повторам"])
        for m in METRICS:
            for k in sorted(S):
                s = S[k][m]
                if s["n"] == 0:
                    continue
                vals = " ".join(f"{r[m]:.3f}" for r in results[k])
                w.writerow([NAMES[m], gb(k[0]), k[1], s["n"]]
                           + [f"{s[x]:.4f}".replace(".", ",") for x in ("med", "q1", "q3", "iqr", "cv")] + [vals])
                lines.append(f"{NAMES[m]:36s} {gb(k[0]):>4s} {k[1]:7s} n={s['n']}  "
                             f"med={s['med']:.3f}  IQR={s['iqr']:.3f}  CV={s['cv']:.1f}%")
    for I, (u, p) in tests.items():
        lines.append(f"U-критерий Манна - Уитни, приток {gb(I)} ГБ/сут: U = {u:g}, p = {p:.4f}")
    with open(os.path.join(out, "summary.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


def make_figures(results, S, out, days):
    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "axes.edgecolor": "#8a8984", "xtick.color": "#52514e", "ytick.color": "#52514e",
                         "grid.color": "#e4e3de", "grid.linewidth": 0.8})
    Is = sorted({k[0] for k in results})

    # рисунок 6: динамика в первом повторе при наибольшей интенсивности
    fig, ax = plt.subplots(figsize=(7.2, 3.4), dpi=200)
    for sch in SCHEDS:
        if (Is[-1], sch) in results and results[(Is[-1], sch)][0]["hourly"]:
            h = results[(Is[-1], sch)][0]["hourly"]
            ax.plot(np.arange(len(h)) / 24, h, color=C[sch], lw=2, label=LAB[sch])
    for d in range(7, days + 1, 7):
        ax.axvline(d, color="#b5b4ae", lw=0.8, ls="--")
    ax.set_xlabel("Время от начала серии, сут")
    ax.set_ylabel("Неоптимизированные данные, ГБ")
    ax.set_xlim(0, days); ax.set_ylim(0, None); ax.set_xticks(range(0, days + 1)); ax.grid(axis="y")
    ax.legend(frameon=False, loc="upper left")
    fig.tight_layout(); fig.savefig(os.path.join(out, "fig6_dynamics.png")); plt.close(fig)

    # рисунок 7: средний объем перед запуском по повторам, медиана и IQR
    fig, axes = plt.subplots(1, len(Is), figsize=(7.2, 3.3), dpi=200, squeeze=False)
    for ax, I in zip(axes[0], Is):
        for i, sch in enumerate(SCHEDS):
            if (I, sch) not in results:
                continue
            v = [r["mean_prejob"] for r in results[(I, sch)]]
            ax.scatter(i + np.linspace(-0.12, 0.12, len(v)), v, s=36, color=C[sch], edgecolor="white",
                       linewidth=1.5, zorder=3)
            st = S[(I, sch)]["mean_prejob"]
            ax.plot([i - 0.25, i + 0.25], [st["med"]] * 2, color="#0b0b0b", lw=2, zorder=4)
            ax.fill_between([i - 0.25, i + 0.25], st["q1"], st["q3"], color=C[sch], alpha=0.18, lw=0)
            ax.annotate(f"{st['med']:.1f}", (i + 0.28, st["med"]), va="center", fontsize=9)
        ax.set_xticks([0, 1]); ax.set_xticklabels(["Ежедневно", "Еженедельно"]); ax.set_xlim(-0.5, 1.7)
        ax.set_ylim(0, None); ax.set_title(f"Приток {gb(I)} ГБ/сут", fontsize=10); ax.grid(axis="y")
    axes[0][0].set_ylabel("Ср. объем перед запуском, ГБ")
    fig.tight_layout(); fig.savefig(os.path.join(out, "fig7_prejob.png")); plt.close(fig)

    # рисунок 8: длительность заданий (медианы)
    fig, axes = plt.subplots(1, 2, figsize=(7.2, 3.2), dpi=200)
    xs = np.arange(len(Is)); w = 0.36
    for ax, m, ttl in ((axes[0], "job_mean_min", "Среднее время одного запуска"),
                       (axes[1], "job_total_min", "Суммарное время за серию")):
        for j, sch in enumerate(SCHEDS):
            vals = [S[(I, sch)][m]["med"] if (I, sch) in S else np.nan for I in Is]
            pos = xs + (j - 0.5) * (w + 0.02)
            ax.bar(pos, vals, width=w, color=C[sch], label=LAB[sch])
            for xi, v in zip(pos, vals):
                if not np.isnan(v):
                    ax.text(xi, v, f"{v:.1f}", ha="center", va="bottom", fontsize=8.5)
        ax.set_xticks(xs); ax.set_xticklabels([f"{gb(I)} ГБ/сут" for I in Is])
        ax.set_title(ttl, fontsize=10); ax.grid(axis="y"); ax.set_axisbelow(True)
    axes[0].set_ylabel("Минуты (медиана)")
    axes[0].legend(frameon=False, fontsize=8.5, loc="upper left")
    fig.tight_layout(); fig.savefig(os.path.join(out, "fig8_jobtime.png")); plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description="Обработка результатов эксперимента SOS-013")
    ap.add_argument("--results", required=True, help="каталог results, созданный 03-Host-RunAll.ps1")
    ap.add_argument("--out", help="каталог для сводки и рисунков (по умолчанию <results>\\analysis)")
    a = ap.parse_args()
    out = a.out or os.path.join(a.results, "analysis")
    os.makedirs(out, exist_ok=True)
    results, days = load_results(a.results)
    missing = [(gb(I), s) for I in sorted({k[0] for k in results}) for s in SCHEDS if (I, s) not in results]
    if missing:
        sys.exit(f"Нет данных для комбинаций: {missing}")
    S, tests = summarize(results)
    write_summary(results, S, tests, out)
    make_figures(results, S, out, days)
    results8, _ = load_results(a.results, min_ram=8)
    extended_analysis(results, results8, out)
    print(f"\nСводка и рисунки сохранены в {out}")


if __name__ == "__main__":
    main()
