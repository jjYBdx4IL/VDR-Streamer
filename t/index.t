# vim:set shiftwidth=4 tabstop=4 expandtab ai smartindent fileformat=unix fileencoding=utf-8 syntax=perl:
use Test::More tests => 10;
use VDR::Index;
use Data::Dumper;
use FindBin;

my $index_vdr = $FindBin::Bin.'/index.vdr';

my $i = VDR::Index->new($index_vdr);

ok($i);
ok(2 == $i->num_pics);

$i->get_pic_info(0);
ok($i->picidx == 0);
ok($i->fileoffset == 0);
ok($i->frametype == 1);
ok($i->fileidx == 1);

ok($i->skip_to_frametype(3)->picidx == 1);
ok($i->fileoffset == 26877);
ok($i->frametype == 3);
ok($i->fileidx == 1);


