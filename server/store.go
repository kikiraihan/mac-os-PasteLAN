package main

import (
	"bytes"
	"context"
	"sync"
	"time"
)

const (
	defaultMaxItems   = 20
	defaultMaxTotalMB = 150 // total isi semua item di memori
	maxText           = 2 << 20
	maxImage          = 30 << 20
	pollDuration      = 25 * time.Second
)

// limits = batas riwayat (diatur dari halaman admin, lihat settings.go)
type limits struct {
	maxItems int
	maxTotal int           // byte
	ttl      time.Duration // 0 = tidak dihapus otomatis berdasarkan umur
}

// item = satu isi clipboard. Hanya di memori; hilang saat server restart, dihapus, atau kedaluwarsa (limits.ttl).
type item struct {
	ID     int64  `json:"id"`
	Kind   string `json:"kind"` // "text" / "image"
	Text   string `json:"text,omitempty"`
	Mime   string `json:"mime,omitempty"`
	Size   int    `json:"size"`
	Time   int64  `json:"time"` // ms sejak epoch
	From   string `json:"from"` // nama perangkat pengirim
	Device string `json:"device"`
	data   []byte
	at     time.Time
}

type store struct {
	mu      sync.Mutex
	items   []*item // terlama di depan
	nextID  int64
	session string        // berubah saat server restart / riwayat dihapus → klien mengosongkan daftarnya
	rev     int64         // naik setiap ada item yang hilang (dihapus / kedaluwarsa) → klien menyesuaikan daftarnya
	changed chan struct{} // ditutup setiap ada perubahan → membangunkan semua long-poll
	lim     limits
}

func newStore(l limits) *store {
	s := &store{nextID: 1, session: randomString(8), changed: make(chan struct{}), lim: l}
	go func() { // buang item kedaluwarsa walau tidak ada yang mengakses
		for range time.Tick(time.Minute) {
			s.mu.Lock()
			if s.prune(time.Now()) {
				s.notify()
			}
			s.mu.Unlock()
		}
	}()
	return s
}

// setLimits dipanggil saat admin mengubah pengaturan; item yang melebihi batas baru langsung dibuang
func (s *store) setLimits(l limits) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lim = l
	if s.prune(time.Now()) {
		s.notify()
	}
}

func (s *store) notify() {
	close(s.changed)
	s.changed = make(chan struct{})
}

// prune membuang item yang kedaluwarsa / melebihi batas (dipanggil dengan s.mu terkunci). true = ada yang dibuang.
func (s *store) prune(now time.Time) bool {
	total := 0
	for _, it := range s.items {
		total += it.Size
	}
	removed := false
	for len(s.items) > 0 && (len(s.items) > s.lim.maxItems || total > s.lim.maxTotal ||
		(s.lim.ttl > 0 && now.Sub(s.items[0].at) > s.lim.ttl)) {
		total -= s.items[0].Size
		s.items[0] = nil
		s.items = s.items[1:]
		removed = true
	}
	if removed {
		s.rev++
	}
	return removed
}

func (s *store) add(it *item) item {
	s.mu.Lock()
	defer s.mu.Unlock()
	// isi yang sama dua kali berturut-turut dari perangkat yang sama → tidak perlu item baru
	if n := len(s.items); n > 0 {
		last := s.items[n-1]
		if last.Device == it.Device && last.Kind == it.Kind && last.Text == it.Text && bytes.Equal(last.data, it.data) {
			return *last
		}
	}
	now := time.Now()
	it.ID, it.at, it.Time = s.nextID, now, now.UnixMilli()
	s.nextID++
	s.items = append(s.items, it)
	s.prune(now)
	s.notify()
	return *it
}

// snapshot = jawaban polling: item dengan id > after (tanpa isi gambar) + id semua item yang masih ada
type snapshot struct {
	session string
	rev     int64
	items   []item
	ids     []int64
}

func (s *store) after(after int64) snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(time.Now())
	out := snapshot{session: s.session, rev: s.rev, items: []item{}, ids: []int64{}}
	for _, it := range s.items {
		out.ids = append(out.ids, it.ID)
		if it.ID > after {
			out.items = append(out.items, *it)
		}
	}
	return out
}

// poll: item baru untuk klien. Session klien beda (klien baru / server restart / riwayat dihapus) → semua item.
// wait → tahan sampai ada item baru, ada item yang hilang (rev ≠ clientRev), atau pollDuration habis (long-poll).
// clientRev < 0 = klien lama yang belum mengenal rev (hanya ditunggu sampai ada item baru).
func (s *store) poll(ctx context.Context, clientSession string, after, clientRev int64, wait bool) snapshot {
	s.mu.Lock()
	session := s.session
	s.mu.Unlock()
	if clientSession != session {
		return s.after(0)
	}
	if wait {
		s.wait(ctx, session, after, clientRev)
	}
	snap := s.after(after)
	if snap.session != session { // riwayat dihapus saat menunggu
		return s.after(0)
	}
	return snap
}

// wait menunggu sampai ada item baru (id > after), item hilang, atau session berubah, maksimal pollDuration
func (s *store) wait(ctx context.Context, session string, after, clientRev int64) {
	timer := time.NewTimer(pollDuration)
	defer timer.Stop()
	for {
		s.mu.Lock()
		ch := s.changed
		ready := s.session != session || (len(s.items) > 0 && s.items[len(s.items)-1].ID > after) ||
			(clientRev >= 0 && s.rev != clientRev)
		s.mu.Unlock()
		if ready {
			return
		}
		select {
		case <-ch:
		case <-timer.C:
			return
		case <-ctx.Done():
			return
		}
	}
}

func (s *store) image(id int64) *item {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(time.Now())
	for _, it := range s.items {
		if it.ID == id && it.Kind == "image" {
			cp := *it
			return &cp
		}
	}
	return nil
}

// remove menghapus satu item (semua perangkat ikut menghapusnya lewat ids di jawaban polling)
func (s *store) remove(id int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, it := range s.items {
		if it.ID == id {
			s.items = append(s.items[:i:i], s.items[i+1:]...)
			s.rev++
			s.notify()
			return true
		}
	}
	return false
}

func (s *store) clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items = nil
	s.session = randomString(8)
	s.notify()
}

// stats untuk halaman admin
func (s *store) stats() (count, bytes int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(time.Now())
	for _, it := range s.items {
		bytes += it.Size
	}
	return len(s.items), bytes
}
