package main

import (
	"bytes"
	"context"
	"sync"
	"time"
)

const (
	maxItems     = 20
	maxTotal     = 150 << 20 // total isi semua item di memori
	maxText      = 2 << 20
	maxImage     = 30 << 20
	itemTTL      = 24 * time.Hour
	pollDuration = 25 * time.Second
)

// item = satu isi clipboard. Hanya di memori; hilang saat server restart atau setelah itemTTL.
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
	changed chan struct{} // ditutup setiap ada perubahan → membangunkan semua long-poll
}

func newStore() *store {
	s := &store{nextID: 1, session: randomString(8), changed: make(chan struct{})}
	go func() { // buang item kedaluwarsa walau tidak ada yang mengakses
		for range time.Tick(10 * time.Minute) {
			s.mu.Lock()
			s.prune(time.Now())
			s.mu.Unlock()
		}
	}()
	return s
}

func (s *store) notify() {
	close(s.changed)
	s.changed = make(chan struct{})
}

// prune membuang item yang kedaluwarsa / melebihi batas (dipanggil dengan s.mu terkunci)
func (s *store) prune(now time.Time) {
	total := 0
	for _, it := range s.items {
		total += it.Size
	}
	for len(s.items) > 0 && (len(s.items) > maxItems || total > maxTotal || now.Sub(s.items[0].at) > itemTTL) {
		total -= s.items[0].Size
		s.items[0] = nil
		s.items = s.items[1:]
	}
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

// after: item dengan id > after (tanpa isi gambar)
func (s *store) after(after int64) (string, []item) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.prune(time.Now())
	out := []item{}
	for _, it := range s.items {
		if it.ID > after {
			out = append(out, *it)
		}
	}
	return s.session, out
}

// poll: item baru untuk klien. Session klien beda (klien baru / server restart / riwayat dihapus) → semua item.
// wait → tahan sampai ada item baru atau pollDuration habis (long-poll).
func (s *store) poll(ctx context.Context, clientSession string, after int64, wait bool) (string, []item) {
	s.mu.Lock()
	session := s.session
	s.mu.Unlock()
	if clientSession != session {
		return s.after(0)
	}
	if wait {
		s.wait(ctx, session, after)
	}
	cur, list := s.after(after)
	if cur != session { // riwayat dihapus saat menunggu
		return s.after(0)
	}
	return cur, list
}

// wait menunggu sampai ada item baru (id > after) atau session berubah, maksimal pollDuration
func (s *store) wait(ctx context.Context, session string, after int64) {
	timer := time.NewTimer(pollDuration)
	defer timer.Stop()
	for {
		s.mu.Lock()
		ch := s.changed
		ready := s.session != session || (len(s.items) > 0 && s.items[len(s.items)-1].ID > after)
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

func (s *store) clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items = nil
	s.session = randomString(8)
	s.notify()
}
