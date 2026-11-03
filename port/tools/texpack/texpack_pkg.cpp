// texpack_pkg.cpp: the engine's own .res package reader (FileIO/FilesPackage), wrapped for the texpack tool, so the
// archive index is read exactly as the game reads it.
#include "../../../FileIO/StdAfx.h"
#include "../../../FileIO/FilesPackage.h"
#include "texpack_pkg.h"

#include <mutex>
static CPtr<IFilesPackage> s_pack;
static std::mutex s_lock;   // the package stream has one file position

bool PkgOpen(const char *path)
{
	s_pack = OpenFilesPackage(path);
	return s_pack != 0;
}

void PkgList(std::vector<std::pair<int, unsigned>> *out)
{
	vector< pair<FILE_ID, unsigned int> > files;
	ListPackageFiles(s_pack, &files);
	out->assign(files.begin(), files.end());
}

bool PkgRead(int id, std::vector<unsigned char> *out)
{
	std::lock_guard<std::mutex> l(s_lock);
	if (!DoesFileExist(s_pack, id)) return false;
	CPackageStream s(s_pack, id);
	out->resize(s.GetSize());
	if (out->empty()) return true;
	s.Read(out->data(), (unsigned)out->size());
	return true;
}
