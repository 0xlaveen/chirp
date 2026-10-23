#!/usr/bin/env python3
"""Deterministic Xcode project. Prerequisites: Python 3 standard library; no XcodeGen."""
from pathlib import Path
import hashlib
import json
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
objects = {}

def oid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def add(identity, **value):
    key = oid(identity)
    objects[key] = value
    return key

def atom(value):
    if isinstance(value, dict):
        return '{\n' + ''.join(f'{atom(k)} = {atom(v)};\n' for k, v in sorted(value.items())) + '}'
    if isinstance(value, list):
        return '(' + ', '.join(atom(x) for x in value) + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=True)

def file(path, kind='sourcecode.swift'):
    return add('file:' + path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='SOURCE_ROOT')

def configs(name, settings):
    refs = []
    for mode in ('Debug', 'Release'):
        values = dict(settings)
        if mode == 'Debug':
            # Swift package products use the destination's active architecture in
            # Debug. Extensions must match it rather than also requesting x86_64
            # modules that the arm64 package build does not produce.
            values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone', DEBUG_INFORMATION_FORMAT='dwarf', ENABLE_TESTABILITY='YES', ONLY_ACTIVE_ARCH='YES')
            values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = values.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '$(inherited)') + ' DEBUG'
        else:
            values.update(SWIFT_OPTIMIZATION_LEVEL='-O', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym', ENABLE_TESTABILITY='NO')
        refs.append(add(f'config:{name}:{mode}', isa='XCBuildConfiguration', name=mode, buildSettings=values,
                        baseConfigurationReference=config_ref))
    return add('configs:' + name, isa='XCConfigurationList', buildConfigurations=refs,
               defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')

config_ref = file('Config/Project.xcconfig', 'text.xcconfig')
shared = add('package:Shared', isa='XCLocalSwiftPackageReference', relativePath='Shared')
policy = add('package:Policy', isa='XCLocalSwiftPackageReference', relativePath='Keyboard/Policy')
target_ids = {name: oid('target:' + name) for name in ('ChirpIOS', 'ChirpKeyboard', 'ChirpWidgets', 'ChirpIOSTests', 'ChirpIOSUITests')}
all_files = [config_ref]
products = []
source_membership = {}

def sources(*patterns):
    return sorted({str(p.relative_to(ROOT)) for pattern in patterns for p in ROOT.glob(pattern)
                   if p.is_file() and '.build' not in p.parts and 'Tests' not in p.parts and p.name != 'Package.swift'})

memberships = {
    'ChirpIOS': sources('App/**/*.swift', 'Intents/*.swift'),
    'ChirpKeyboard': sources('Keyboard/*.swift', 'Keyboard/UI/**/*.swift'),
    'ChirpWidgets': sources('Widgets/**/*.swift', 'Intents/SessionIntents.swift', 'Intents/ChirpActivityAttributes.swift',
                             'Intents/NotesIntents.swift', 'Intents/NotesActivityAttributes.swift'),
    'ChirpIOSTests': sorted(str(p.relative_to(ROOT)) for p in ROOT.glob('Tests/**/*.swift')),
    'ChirpIOSUITests': sorted(str(p.relative_to(ROOT)) for p in ROOT.glob('UITests/**/*.swift')),
}
for name, paths in memberships.items():
    source_membership[name] = paths
    test = name.endswith('Tests')
    extension = name in ('ChirpKeyboard', 'ChirpWidgets')
    product_name = name + ('.appex' if extension else '.xctest' if test else '.app')
    product_kind = 'wrapper.app-extension' if extension else 'wrapper.cfbundle' if test else 'wrapper.application'
    product = add('product:' + name, isa='PBXFileReference', explicitFileType=product_kind,
                  path=product_name, sourceTree='BUILT_PRODUCTS_DIR', includeInIndex=0)
    products.append(product)
    src = []
    for path in paths:
        ref = file(path)
        if ref not in all_files: all_files.append(ref)
        src.append(add(f'build:{name}:{path}', isa='PBXBuildFile', fileRef=ref))
    phases = [add('sources:' + name, isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=src, runOnlyForDeploymentPostprocessing=0)]
    packages = []
    links = []
    for product_name, package in ([('ChirpIOSCore', shared), ('ChirpCore', add('package:mac', isa='XCLocalSwiftPackageReference', relativePath='../mac'))]
                                  if name in ('ChirpIOS', 'ChirpKeyboard', 'ChirpIOSTests') else []):
        dep = add(f'packageproduct:{name}:{product_name}', isa='XCSwiftPackageProductDependency', package=package, productName=product_name)
        packages.append(dep)
        links.append(add(f'link:{name}:{product_name}', isa='PBXBuildFile', productRef=dep))
    if name == 'ChirpKeyboard':
        dep = add('packageproduct:KeyboardPolicy', isa='XCSwiftPackageProductDependency', package=policy, productName='KeyboardPolicy')
        packages.append(dep)
        links.append(add('link:KeyboardPolicy', isa='PBXBuildFile', productRef=dep))
    phases.append(add('frameworks:' + name, isa='PBXFrameworksBuildPhase', buildActionMask=2147483647, files=links, runOnlyForDeploymentPostprocessing=0))
    resources = []
    if name == 'ChirpIOS':
        assets = file('App/Assets.xcassets', 'folder.assetcatalog')
        all_files.append(assets)
        resources.append(add('resource:AppAssets', isa='PBXBuildFile', fileRef=assets))
    phases.append(add('resources:' + name, isa='PBXResourcesBuildPhase', buildActionMask=2147483647, files=resources, runOnlyForDeploymentPostprocessing=0))
    dependencies = []
    if name == 'ChirpIOS':
        embeds = []
        for ext in ('ChirpKeyboard', 'ChirpWidgets'):
            embeds.append(add('embed:' + ext, isa='PBXBuildFile', fileRef=oid('product:' + ext), settings={'ATTRIBUTES': ['CodeSignOnCopy', 'RemoveHeadersOnCopy']}))
            dependencies.append(add('dependency:' + ext, isa='PBXTargetDependency', target=target_ids[ext]))
        phases.append(add('embed-extensions', isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647,
                          dstPath='', dstSubfolderSpec=13, files=embeds, name='Embed App Extensions', runOnlyForDeploymentPostprocessing=0))
    suffix = {'ChirpIOS':'', 'ChirpKeyboard':'.keyboard', 'ChirpWidgets':'.widgets', 'ChirpIOSTests':'.tests', 'ChirpIOSUITests':'.uitests'}[name]
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='$(CHIRP_BUNDLE_ID)' + suffix,
                    SUPPORTED_PLATFORMS='iphonesimulator iphoneos', SDKROOT='iphoneos', TARGETED_DEVICE_FAMILY='1,2')
    if test:
        dependencies.append(add('dependency:' + name, isa='PBXTargetDependency', target=target_ids['ChirpIOS']))
        settings.update(GENERATE_INFOPLIST_FILE='YES')
        if name == 'ChirpIOSTests':
            settings.update(TEST_HOST='$(BUILT_PRODUCTS_DIR)/ChirpIOS.app/ChirpIOS', BUNDLE_LOADER='$(TEST_HOST)')
        else:
            settings.update(TEST_TARGET_NAME='ChirpIOS')
    else:
        prefix = 'App' if name == 'ChirpIOS' else 'Keyboard' if name == 'ChirpKeyboard' else 'Widgets'
        settings.update(INFOPLIST_FILE=f'Config/{prefix}-Info.plist', CODE_SIGN_ENTITLEMENTS=f'Config/{prefix}.entitlements',
                        GENERATE_INFOPLIST_FILE='NO', SKIP_INSTALL='YES' if extension else 'NO')
        if extension: settings.update(APPLICATION_EXTENSION_API_ONLY='YES')
        if name == 'ChirpIOS': settings.update(SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) CHIRP_APP', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon')
    product_type = 'com.apple.product-type.app-extension' if extension else ('com.apple.product-type.bundle.ui-testing' if name == 'ChirpIOSUITests' else 'com.apple.product-type.bundle.unit-test') if test else 'com.apple.product-type.application'
    add('target:' + name, isa='PBXNativeTarget', name=name, productName=name, productReference=product,
        productType=product_type, buildConfigurationList=configs(name, settings), buildPhases=phases,
        buildRules=[], dependencies=dependencies, packageProductDependencies=packages)

product_group = add('products', isa='PBXGroup', children=products, name='Products', sourceTree='<group>')
main_group = add('rootgroup', isa='PBXGroup', children=all_files+[product_group], sourceTree='<group>')
project = add('project', isa='PBXProject', attributes={'BuildIndependentTargetsInParallel':'YES', 'LastUpgradeCheck':'1600'},
              buildConfigurationList=configs('project', {}), compatibilityVersion='Xcode 15.0', developmentRegion='en',
              knownRegions=['en','Base'], mainGroup=main_group, productRefGroup=product_group, projectDirPath='', projectRoot='',
              packageReferences=[shared, policy, oid('package:mac')], targets=list(target_ids.values()))
out = ROOT / 'Chirp.xcodeproj'
out.mkdir(exist_ok=True)
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n' + atom(dict(archiveVersion=1, classes={}, objectVersion=60, objects=objects, rootObject=project)) + '\n')
(out/'source-membership.json').write_text(json.dumps(source_membership, indent=2) + '\n')
schemes = out/'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
for scheme, tests in [('ChirpIOS', ['ChirpIOSTests']), ('ChirpIOS-UI', ['ChirpIOSUITests'])]:
    def ref(name):
        ext = '.xctest' if name.endswith('Tests') else '.app'
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{name}{ext}" BlueprintName="{name}" ReferencedContainer="container:Chirp.xcodeproj"/>'
    testrefs = ''.join(f'<TestableReference skipped="NO">{ref(t)}</TestableReference>' for t in tests)
    testbuilds = ''.join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(t)}</BuildActionEntry>' for t in tests)
    (schemes/f'{scheme}.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('ChirpIOS')}</BuildActionEntry>{testbuilds}</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testrefs}</Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('ChirpIOS')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('ChirpIOS')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated {out.relative_to(ROOT)}; {sum(map(len, memberships.values()))} Swift memberships')
