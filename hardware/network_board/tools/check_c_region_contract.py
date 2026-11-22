"""Exhaust the fixed strip geometry, without synthesizing any debug hardware."""
checks = 0
for frame_width4 in range(2, 481):
    for start in range(0, frame_width4, 120):
        def clip(halo):
            return max(0, start - halo), min(frame_width4, start + 120 + halo)
        for body, halo, capacity in [(0, 5, 130), (1, 4, 128), (2, 3, 126), (3, 2, 124)]:
            lo, hi = clip(halo)
            assert 0 <= lo < hi <= frame_width4
            assert hi - lo <= capacity
            for parity in (0, 1):
                bases = [(0,508),(130,638),(258,766),(384,892)]
                addr_lo = bases[body][parity]
                addr_hi = addr_lo + hi - lo
                assert addr_lo >= 0 and addr_hi <= (508 if parity == 0 else 1016)
                if body < 3:
                    assert addr_hi <= bases[body + 1][parity]
                checks += 1
print(f'PASS fixed C center region contract: all 479 supported widths, all strips, 4 bodies, 2 parities; {checks} checks')
